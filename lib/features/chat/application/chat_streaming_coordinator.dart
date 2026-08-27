import 'package:dio/dio.dart';
import '../../../core/logging/app_logger.dart';
export 'chat_stream_request.dart';
import 'background_task_bridge.dart';
import 'chat_stream_request.dart';
import 'chat_stream_support.dart';
import 'chat_tool_executor.dart';
import 'chat_tool_runtime.dart';
import 'fallback_tool_call_parser.dart';
import '../../../features/memory/application/instant_memory_writer.dart';
import '../../../features/memory/application/persona_registry.dart';
import '../data/chat_repository.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import '../domain/chat_tool.dart';
import '../domain/pending_memory_proposal.dart';

class ChatStreamingCoordinator {
  ChatStreamingCoordinator({
    required ChatCompletionStreamer streamer,
    required Conversation? Function(String id) conversationById,
    required Future<void> Function(Conversation conversation) persistAndPublish,
    required void Function(String message) publishError,
    ChatToolRuntime? toolRuntime,
    BackgroundTaskBridge backgroundTasks = const NoopBackgroundTaskBridge(),
    InstantMemoryWriter? instantMemoryWriter,
    PersonaRegistryAdapter? personaRegistry,
    void Function(String event)? onTransientRetry,
    AppLogger? logger,
  }) : _streamer = streamer,
       _conversationById = conversationById,
       _persistAndPublish = persistAndPublish,
       _publishError = publishError,
       _toolRuntime = toolRuntime,
       _backgroundTasks = backgroundTasks,
       _instantMemoryWriter = instantMemoryWriter,
       _personaRegistry = personaRegistry,
       _onTransientRetry = onTransientRetry,
       _logger = logger;

  final ChatCompletionStreamer _streamer;
  final Conversation? Function(String id) _conversationById;
  final Future<void> Function(Conversation conversation) _persistAndPublish;
  final void Function(String message) _publishError;
  final ChatToolRuntime? _toolRuntime;
  final InstantMemoryWriter? _instantMemoryWriter;
  final PersonaRegistryAdapter? _personaRegistry;
  final BackgroundTaskBridge _backgroundTasks;
  final void Function(String event)? _onTransientRetry;
  final AppLogger? _logger;
  ChatToolExecutor? get _toolExecutor => _toolRuntime == null
      ? null
      : ChatToolExecutor(
          runtime: _toolRuntime,
          conversationById: _conversationById,
          persistAndPublish: _persistAndPublish,
          instantMemoryWriter: _instantMemoryWriter,
          personaRegistry: _personaRegistry,
          logger: _logger,
        );

  static const maxTransientRetries = 1;

  ChatStreamRequest? _activeRequest;
  CancelToken? _cancelToken;
  Future<void>? _running;
  final Set<String> _memoryDecisions = {};
  Future<void> run(ChatStreamRequest request) {
    if (_running != null) {
      throw StateError('A chat request is already running');
    }
    final operation = _run(request);
    _running = operation;
    return operation;
  }

  Future<void> continueAfterMemoryDecision({
    required Conversation conversation,
    required PendingMemoryProposal proposal,
    required String toolResult,
  }) async {
    final decisionId =
        '${conversation.id}:${proposal.assistantMessageId}:'
        '${proposal.toolCallId}:${proposal.callOccurrence}';
    if (!_memoryDecisions.add(decisionId)) return;
    final currentProposal = _conversationById(
      conversation.id,
    )?.pendingMemoryProposal;
    if (currentProposal?.toolCallId != proposal.toolCallId ||
        currentProposal?.assistantMessageId != proposal.assistantMessageId ||
        currentProposal?.callOccurrence != proposal.callOccurrence) {
      _memoryDecisions.remove(decisionId);
      return;
    }
    if (_running != null) {
      _memoryDecisions.remove(decisionId);
      throw StateError('A chat request is already running');
    }
    final now = DateTime.now();
    final assistantId = '${now.microsecondsSinceEpoch}-assistant';
    final messages = [...conversation.messages];
    final proposalAssistantIndex = messages.indexWhere(
      (message) => message.id == proposal.assistantMessageId,
    );
    final toolResultMessage = ChatMessage(
      id: '${now.microsecondsSinceEpoch}-tool',
      role: ChatRole.tool,
      content: toolResult,
      createdAt: now,
      toolCallId: proposal.toolCallId,
    );
    if (proposalAssistantIndex < 0) {
      messages.add(toolResultMessage);
    } else {
      var insertionIndex = proposalAssistantIndex + 1;
      var matchingResults = 0;
      while (insertionIndex < messages.length &&
          messages[insertionIndex].role == ChatRole.tool) {
        if (messages[insertionIndex].toolCallId == proposal.toolCallId) {
          if (matchingResults >= proposal.callOccurrence) break;
          matchingResults++;
        }
        insertionIndex++;
      }
      messages.insert(insertionIndex, toolResultMessage);
    }
    final updated = conversation.copyWith(
      updatedAt: now,
      clearPendingMemoryProposal: true,
      messages: [
        ...messages,
        ChatMessage(
          id: assistantId,
          role: ChatRole.assistant,
          content: '',
          createdAt: now,
          status: ChatMessageStatus.pending,
        ),
      ],
    );
    await _persistAndPublish(updated);
    await run(
      buildChatStreamRequest(
        updated,
        updated.pendingRequestMessageId!,
        assistantId,
        selectedAgentId: proposal.selectedAgentId,
        allowedTools: proposal.allowedTools,
      ),
    );
  }

  void cancel(String conversationId) {
    if (_activeRequest?.conversationId == conversationId) {
      _cancelToken?.cancel('Cancelled by user');
    }
  }

  Future<void> cancelAndWait(String conversationId) async {
    if (_activeRequest?.conversationId != conversationId) return;
    _cancelToken?.cancel('Conversation deleted');
    await _running;
  }

  Future<void> _run(ChatStreamRequest request) async {
    final cancelToken = CancelToken();
    _activeRequest = request;
    _cancelToken = cancelToken;
    try {
      await _backgroundTasks.start(title: request.conversationTitle);
      var history = request.history;
      var assistantId = request.assistantMessageId;
      var toolRounds = 0;
      var transientRetriesLeft = maxTransientRetries;
      final tools =
          await _toolRuntime?.availableTools(request.allowedTools) ??
          const <ChatToolDefinition>[];
      while (true) {
        var terminalSeen = false;
        String? finishReason;
        var receivedAnyToken = false;
        final buffers = <int, ToolCallBuffer>{};
        try {
          await for (final event in _streamer.streamCompletion(
            model: request.modelId,
            messages: history,
            cancelToken: cancelToken,
            tools: tools,
          )) {
            receivedAnyToken =
                receivedAnyToken ||
                event.delta.isNotEmpty ||
                event.reasoningDelta.isNotEmpty ||
                event.toolCallDeltas.isNotEmpty;
            final latest = _conversationById(request.conversationId);
            if (latest == null) {
              cancelToken.cancel('Conversation deleted');
              return;
            }
            for (final delta in event.toolCallDeltas) {
              buffers
                  .putIfAbsent(delta.index, ToolCallBuffer.new)
                  .append(delta);
            }
            terminalSeen = terminalSeen || event.isTerminal;
            finishReason = event.finishReason ?? finishReason;
            final updated = latest.copyWith(
              updatedAt: DateTime.now(),
              usage: event.usage == null
                  ? null
                  : ConversationUsage.fromChatUsage(event.usage!),
              messages: latest.messages
                  .map(
                    (message) => message.id == assistantId
                        ? message.copyWith(
                            content: '${message.content}${event.delta}',
                            reasoningContent:
                                '${message.reasoningContent}'
                                '${event.reasoningDelta}',
                            status: ChatMessageStatus.streaming,
                          )
                        : message,
                  )
                  .toList(),
            );
            await _persistAndPublish(updated);
          }
          if (terminalSeen && finishReason == 'tool_calls') {
            toolRounds++;
            if (toolRounds > 8) {
              throw const FormatException('Tool call round limit exceeded');
            }
            final ordered = buffers.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key));
            final shouldContinue = await _executeTools(
              request,
              assistantId,
              ordered.map((entry) => entry.value.build()).toList(),
            );
            if (!shouldContinue) return;
            final conversation = _conversationById(request.conversationId)!;
            history = conversation.messages
                .where(
                  (message) => message.status == ChatMessageStatus.complete,
                )
                .toList(growable: false);
            assistantId = '${request.assistantMessageId}-followup-$toolRounds';
            await _appendPendingAssistant(request, assistantId);
            continue;
          }
          if (terminalSeen && buffers.isEmpty) {
            final conversation = _conversationById(request.conversationId)!;
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
              await _persistAndPublish(
                conversation.copyWith(
                  updatedAt: DateTime.now(),
                  messages: conversation.messages
                      .map(
                        (message) => message.id == assistantId
                            ? message.copyWith(content: parsed.visibleText)
                            : message,
                      )
                      .toList(),
                ),
              );
            }
            if (parsed.calls.isNotEmpty) {
              toolRounds++;
              if (toolRounds > 8) {
                throw const FormatException('Tool call round limit exceeded');
              }
              final shouldContinue = await _executeTools(
                request,
                assistantId,
                parsed.calls,
              );
              if (!shouldContinue) return;
              final updated = _conversationById(request.conversationId)!;
              history = updated.messages
                  .where(
                    (message) => message.status == ChatMessageStatus.complete,
                  )
                  .toList(growable: false);
              assistantId =
                  '${request.assistantMessageId}-followup-$toolRounds';
              await _appendPendingAssistant(request, assistantId);
              continue;
            }
          }
        } on DioException catch (error) {
          final retryable =
              isTransientChatError(error) &&
              !receivedAnyToken &&
              !terminalSeen &&
              buffers.isEmpty &&
              transientRetriesLeft > 0;
          if (retryable) {
            transientRetriesLeft--;
            _onTransientRetry?.call('chat.transient_retry');
            await Future<void>.delayed(const Duration(seconds: 1));
            continue;
          }
          rethrow;
        }
        if (cancelToken.isCancelled) {
          await _finish(request, ChatMessageStatus.interrupted);
        } else if (terminalSeen) {
          await _finish(request, ChatMessageStatus.complete);
        } else {
          await _interruptWithError(
            request,
            'The response stream closed before completion. Retry the interrupted response.',
          );
        }
        return;
      }
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        await _finish(request, ChatMessageStatus.interrupted);
      } else {
        await _interruptWithError(request, friendlyChatError(error));
      }
    } on FormatException catch (error) {
      await _interruptWithError(request, error.message);
    } on Object catch (error) {
      _logger?.log(
        event: 'chat.streaming',
        level: AppLogLevel.error,
        conversationId: request.conversationId,
        status: 'failed',
        error: error,
      );
      await _interruptWithError(
        request,
        'The request failed unexpectedly. Please retry.',
      );
    } finally {
      if (identical(_activeRequest, request)) {
        _activeRequest = null;
        _cancelToken = null;
        _running = null;
      }
      try {
        await _backgroundTasks.stop();
      } on Object {
        // Background cleanup is best-effort after request state is finalized.
      }
    }
  }

  Future<bool> _executeTools(
    ChatStreamRequest request,
    String assistantId,
    List<ChatToolCall> calls,
  ) async {
    final executor = _toolExecutor;
    if (executor == null || calls.isEmpty) {
      throw const FormatException('Tool call response has no executable calls');
    }
    return executor.execute(request, assistantId, calls);
  }

  Future<void> _appendPendingAssistant(
    ChatStreamRequest request,
    String assistantId,
  ) async {
    final conversation = _conversationById(request.conversationId)!;
    await _persistAndPublish(
      conversation.copyWith(
        updatedAt: DateTime.now(),
        messages: [
          ...conversation.messages,
          ChatMessage(
            id: assistantId,
            role: ChatRole.assistant,
            content: '',
            createdAt: DateTime.now(),
            status: ChatMessageStatus.pending,
          ),
        ],
      ),
    );
  }

  Future<void> _interruptWithError(
    ChatStreamRequest request,
    String message,
  ) async {
    await _finish(request, ChatMessageStatus.interrupted);
    _publishError(message);
  }

  Future<void> _finish(
    ChatStreamRequest request,
    ChatMessageStatus status,
  ) async {
    final conversation = _conversationById(request.conversationId);
    if (conversation == null) return;
    final updated = conversation.copyWith(
      updatedAt: DateTime.now(),
      clearPendingRequest: status == ChatMessageStatus.complete,
      messages: conversation.messages
          .map(
            (message) =>
                message.role == ChatRole.assistant &&
                    (message.status == ChatMessageStatus.pending ||
                        message.status == ChatMessageStatus.streaming)
                ? message.copyWith(status: status)
                : message,
          )
          .toList(),
    );
    await _persistAndPublish(updated);
  }
}
