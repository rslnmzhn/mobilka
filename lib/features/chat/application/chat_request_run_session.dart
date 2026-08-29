import 'package:dio/dio.dart';

import '../../../core/logging/app_logger.dart';
import '../data/chat_repository.dart';
import '../domain/chat_message.dart';
import '../domain/chat_stream_event.dart';
import '../domain/chat_tool.dart';
import '../domain/conversation.dart';
import 'chat_stream_finalizer.dart';
import 'chat_stream_request.dart';
import 'chat_stream_support.dart';
import 'fallback_tool_call_parser.dart';
import 'request_tool_security_state.dart';
import 'skill_reflection_runner.dart';
import 'chat_tool_runtime.dart';
import 'conversation_mutation.dart';

typedef ExecuteRequestTools =
    Future<bool> Function(String assistantId, List<ChatToolCall> calls);

class ChatRequestRunSession {
  ChatRequestRunSession({
    required this.request,
    required this.streamer,
    required this.conversationById,
    required this.persistMutation,
    required this.finalizer,
    required this.security,
    required this.cancelToken,
    required this.tools,
    required this.executeTools,
    required this.appendPendingAssistant,
    required this.toolRuntime,
    required this.onTransientRetry,
    required this.onFinalSuccess,
    required this.logger,
  }) : history = request.history,
       assistantId = request.assistantMessageId;

  final ChatStreamRequest request;
  final ChatCompletionStreamer streamer;
  final Conversation? Function(String id) conversationById;
  final PersistConversationMutation persistMutation;
  final ChatStreamFinalizer finalizer;
  final RequestToolSecurityState security;
  final CancelToken cancelToken;
  final List<ChatToolDefinition> tools;
  final ExecuteRequestTools executeTools;
  final Future<void> Function(String assistantId) appendPendingAssistant;
  final ChatToolRuntime? toolRuntime;
  final void Function(String event)? onTransientRetry;
  final void Function(ChatStreamRequest request, String assistantText)?
  onFinalSuccess;
  final AppLogger? logger;

  List<ChatMessage> history;
  String assistantId;
  var toolRounds = 0;
  var transientRetriesLeft = 1;

  Future<void> run() async {
    while (true) {
      final round = _StreamRound();
      try {
        await _consume(round);
        final toolOutcome = await _afterTools(round);
        if (toolOutcome == _ToolRoundOutcome.continueStreaming) continue;
        if (toolOutcome == _ToolRoundOutcome.stop) return;
      } on DioException catch (error) {
        if (await _retry(error, round)) continue;
        rethrow;
      }
      await _finish(round);
      return;
    }
  }

  Future<void> _consume(_StreamRound round) async {
    await for (final event in streamer.streamCompletion(
      model: request.modelId,
      messages: history,
      cancelToken: cancelToken,
      tools: tools,
    )) {
      round.record(event);
      final updated = await _persistEvent(event);
      if (updated == null) {
        cancelToken.cancel('Conversation deleted');
        return;
      }
    }
  }

  Future<Conversation?> _persistEvent(ChatStreamEvent event) {
    return persistMutation(request.conversationId, (latest) {
      if (latest.pendingRequestMessageId != request.requestMessageId) {
        return null;
      }
      return latest.copyWith(
        updatedAt: DateTime.now(),
        usage: event.usage == null
            ? null
            : ConversationUsage.fromChatUsage(event.usage!),
        messages: latest.messages.map((message) {
          if (message.id != assistantId) return message;
          return message.copyWith(
            content: '${message.content}${event.delta}',
            reasoningContent:
                '${message.reasoningContent}${event.reasoningDelta}',
            status: ChatMessageStatus.streaming,
          );
        }).toList(),
      );
    });
  }

  Future<_ToolRoundOutcome> _afterTools(_StreamRound round) async {
    if (!round.terminalSeen) return _ToolRoundOutcome.finish;
    if (round.finishReason == 'tool_calls') {
      return _runTools(round.nativeCalls);
    }
    if (round.buffers.isNotEmpty) return _ToolRoundOutcome.finish;
    final parsed = await _fallbackCalls();
    return parsed.isEmpty ? _ToolRoundOutcome.finish : _runTools(parsed);
  }

  Future<List<ChatToolCall>> _fallbackCalls() async {
    final conversation = conversationById(request.conversationId)!;
    final assistant = conversation.messages.firstWhere(
      (message) => message.id == assistantId,
    );
    final parsed = parseFallbackToolCalls(
      assistantText: assistant.content,
      requestMessageId: request.requestMessageId,
      previouslyPersistedCallIds: conversation.messages
          .expand((message) => message.toolCalls)
          .map((call) => call.id)
          .toSet(),
    );
    if (parsed.visibleText != assistant.content) {
      await _replaceAssistantText(parsed.visibleText);
    }
    return parsed.calls;
  }

  Future<void> _replaceAssistantText(String text) async {
    await persistMutation(request.conversationId, (latest) {
      if (latest.pendingRequestMessageId != request.requestMessageId) {
        return latest;
      }
      return latest.copyWith(
        updatedAt: DateTime.now(),
        messages: latest.messages
            .map(
              (message) => message.id == assistantId
                  ? message.copyWith(content: text)
                  : message,
            )
            .toList(),
      );
    });
  }

  Future<_ToolRoundOutcome> _runTools(List<ChatToolCall> calls) async {
    toolRounds++;
    if (toolRounds > 8) {
      throw const FormatException('Tool call round limit exceeded');
    }
    if (!await executeTools(assistantId, calls)) return _ToolRoundOutcome.stop;
    history = conversationById(request.conversationId)!.messages
        .where((message) => message.status == ChatMessageStatus.complete)
        .toList(growable: false);
    assistantId = '${request.assistantMessageId}-followup-$toolRounds';
    await appendPendingAssistant(assistantId);
    return _ToolRoundOutcome.continueStreaming;
  }

  Future<bool> _retry(DioException error, _StreamRound round) async {
    final retryable =
        isTransientChatError(error) &&
        !round.receivedAnyToken &&
        !round.terminalSeen &&
        round.buffers.isEmpty &&
        transientRetriesLeft > 0;
    if (!retryable) return false;
    transientRetriesLeft--;
    onTransientRetry?.call('chat.transient_retry');
    await Future<void>.delayed(const Duration(seconds: 1));
    return true;
  }

  Future<void> _finish(_StreamRound round) async {
    if (cancelToken.isCancelled) {
      await finalizer.finish(request, ChatMessageStatus.interrupted);
    } else if (round.terminalSeen) {
      await _finishTerminal();
    } else {
      await finalizer.interrupt(
        request,
        'The response stream closed before completion. Retry the interrupted response.',
      );
    }
    _logOutcome(round);
  }

  Future<void> _finishTerminal() async {
    await _reflectIfEligible();
    if (!await finalizer.finish(request, ChatMessageStatus.complete)) return;
    final assistant = conversationById(
      request.conversationId,
    )?.messages.where((message) => message.id == assistantId).firstOrNull;
    if (assistant != null) onFinalSuccess?.call(request, assistant.content);
  }

  Future<void> _reflectIfEligible() async {
    final runtime = toolRuntime;
    if (runtime == null) return;
    security.verifiedSnapshot();
    await SkillReflectionRunner(
      streamer: streamer,
      runtime: runtime,
      conversationById: conversationById,
      persistMutation: persistMutation,
      logger: logger,
    ).run(
      request: request,
      finalAssistantId: assistantId,
      security: security,
      cancelToken: cancelToken,
    );
  }

  void _logOutcome(_StreamRound round) {
    logger?.log(
      event: 'chat.stream_outcome',
      conversationId: request.conversationId,
      status: cancelToken.isCancelled
          ? 'cancelled'
          : (round.terminalSeen ? 'terminal' : 'interrupted'),
      terminalSeen: round.terminalSeen,
      receivedAnyToken: round.receivedAnyToken,
      eventCount: round.eventCount,
    );
  }
}

enum _ToolRoundOutcome { finish, continueStreaming, stop }

class _StreamRound {
  var terminalSeen = false;
  String? finishReason;
  var receivedAnyToken = false;
  var eventCount = 0;
  final buffers = <int, ToolCallBuffer>{};

  void record(ChatStreamEvent event) {
    eventCount++;
    receivedAnyToken =
        receivedAnyToken ||
        event.delta.isNotEmpty ||
        event.reasoningDelta.isNotEmpty ||
        event.toolCallDeltas.isNotEmpty;
    for (final delta in event.toolCallDeltas) {
      buffers.putIfAbsent(delta.index, ToolCallBuffer.new).append(delta);
    }
    terminalSeen = terminalSeen || event.isTerminal;
    finishReason = event.finishReason ?? finishReason;
  }

  List<ChatToolCall> get nativeCalls {
    final ordered = buffers.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return ordered.map((entry) => entry.value.build()).toList();
  }
}
