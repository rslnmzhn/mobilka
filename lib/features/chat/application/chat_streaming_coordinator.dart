import 'dart:convert';

import 'package:dio/dio.dart';

import 'chat_tool_runtime.dart';
import '../data/chat_repository.dart';
import '../domain/chat_message.dart';
import '../domain/chat_stream_event.dart';
import '../domain/conversation.dart';
import '../domain/chat_tool.dart';
import '../domain/pending_memory_proposal.dart';

class ChatStreamRequest {
  ChatStreamRequest({
    required this.conversationId,
    required this.requestMessageId,
    required this.assistantMessageId,
    required this.modelId,
    required this.history,
    required this.selectedAgentId,
    required Set<String> allowedTools,
  }) : allowedTools = Set.unmodifiable(allowedTools);

  final String conversationId;
  final String requestMessageId;
  final String assistantMessageId;
  final String modelId;
  final List<ChatMessage> history;
  final String? selectedAgentId;
  final Set<String> allowedTools;
}

({Conversation conversation, ChatStreamRequest request})?
prepareInterruptedRetry(
  Conversation conversation,
  DateTime now, {
  required String? selectedAgentId,
  required Set<String> allowedTools,
}) {
  final requestId = conversation.pendingRequestMessageId;
  if (requestId == null) return null;
  final requestMessage = conversation.messages
      .where((message) => message.id == requestId)
      .firstOrNull;
  if (requestMessage == null || requestMessage.role != ChatRole.user) {
    return null;
  }

  final assistantId = '${now.microsecondsSinceEpoch}-assistant';
  final updated = conversation.copyWith(
    updatedAt: now,
    messages: [
      ...conversation.messages,
      ChatMessage(
        id: assistantId,
        role: ChatRole.assistant,
        content: '',
        createdAt: now,
        status: ChatMessageStatus.pending,
      ),
    ],
  );
  return (
    conversation: updated,
    request: buildChatStreamRequest(
      updated,
      requestId,
      assistantId,
      selectedAgentId: selectedAgentId,
      allowedTools: allowedTools,
    ),
  );
}

ChatStreamRequest buildChatStreamRequest(
  Conversation conversation,
  String requestId,
  String assistantId, {
  required String? selectedAgentId,
  required Set<String> allowedTools,
}) => ChatStreamRequest(
  conversationId: conversation.id,
  requestMessageId: requestId,
  assistantMessageId: assistantId,
  modelId: conversation.modelId,
  selectedAgentId: selectedAgentId,
  allowedTools: allowedTools,
  history: conversation.messages
      .where((message) => message.id != assistantId)
      .where(
        (message) =>
            message.role != ChatRole.assistant ||
            (message.status != ChatMessageStatus.interrupted &&
                message.status != ChatMessageStatus.failed),
      )
      .toList(growable: false),
);

class ChatStreamingCoordinator {
  ChatStreamingCoordinator({
    required ChatCompletionStreamer streamer,
    required Conversation? Function(String id) conversationById,
    required Future<void> Function(Conversation conversation) persistAndPublish,
    required void Function(String message) publishError,
    ChatToolRuntime? toolRuntime,
  }) : _streamer = streamer,
       _conversationById = conversationById,
       _persistAndPublish = persistAndPublish,
       _publishError = publishError,
       _toolRuntime = toolRuntime;

  final ChatCompletionStreamer _streamer;
  final Conversation? Function(String id) _conversationById;
  final Future<void> Function(Conversation conversation) _persistAndPublish;
  final void Function(String message) _publishError;
  final ChatToolRuntime? _toolRuntime;

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
    final decisionId = '${conversation.id}:${proposal.toolCallId}';
    if (!_memoryDecisions.add(decisionId)) return;
    final currentProposal = _conversationById(
      conversation.id,
    )?.pendingMemoryProposal;
    if (currentProposal?.toolCallId != proposal.toolCallId) {
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
      messages.insert(proposalAssistantIndex + 1, toolResultMessage);
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
      var history = request.history;
      var assistantId = request.assistantMessageId;
      var toolRounds = 0;
      final tools =
          await _toolRuntime?.availableTools(request.allowedTools) ??
          const <ChatToolDefinition>[];
      while (true) {
        var terminalSeen = false;
        String? finishReason;
        final buffers = <int, _ToolCallBuffer>{};
        await for (final event in _streamer.streamCompletion(
          model: request.modelId,
          messages: history,
          cancelToken: cancelToken,
          tools: tools,
        )) {
          final latest = _conversationById(request.conversationId);
          if (latest == null) {
            cancelToken.cancel('Conversation deleted');
            return;
          }
          for (final delta in event.toolCallDeltas) {
            buffers.putIfAbsent(delta.index, _ToolCallBuffer.new).append(delta);
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
          final shouldContinue = await _executeTools(
            request,
            assistantId,
            buffers,
          );
          if (!shouldContinue) return;
          final conversation = _conversationById(request.conversationId)!;
          history = conversation.messages
              .where((message) => message.status == ChatMessageStatus.complete)
              .toList(growable: false);
          assistantId = '${request.assistantMessageId}-followup-$toolRounds';
          await _appendPendingAssistant(request, assistantId);
          continue;
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
        await _interruptWithError(request, _friendlyError(error));
      }
    } on FormatException catch (error) {
      await _interruptWithError(request, error.message);
    } on Object catch (error) {
      await _interruptWithError(request, error.toString());
    } finally {
      if (identical(_activeRequest, request)) {
        _activeRequest = null;
        _cancelToken = null;
        _running = null;
      }
    }
  }

  Future<bool> _executeTools(
    ChatStreamRequest request,
    String assistantId,
    Map<int, _ToolCallBuffer> buffers,
  ) async {
    final runtime = _toolRuntime;
    if (runtime == null || buffers.isEmpty) {
      throw const FormatException('Tool call response has no executable calls');
    }
    final ordered = buffers.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final calls = ordered.map((entry) => entry.value.build()).toList();
    var conversation = _conversationById(request.conversationId)!;
    conversation = conversation.copyWith(
      updatedAt: DateTime.now(),
      messages: conversation.messages
          .map(
            (message) => message.id == assistantId
                ? message.copyWith(
                    status: ChatMessageStatus.complete,
                    toolCalls: calls,
                  )
                : message,
          )
          .toList(),
    );
    await _persistAndPublish(conversation);
    PendingMemoryProposal? pendingProposal;
    final results = <ChatMessage>[];
    for (final call in calls) {
      if (call.name == 'update_memory_file') {
        if (pendingProposal != null) {
          results.add(
            _toolErrorResult(
              call,
              'Only one memory proposal can be active per response.',
              results.length,
            ),
          );
          continue;
        }
        try {
          if (runtime is! MemoryProposalRuntime) {
            throw StateError('Memory proposal runtime is unavailable.');
          }
          pendingProposal = await (runtime as MemoryProposalRuntime)
              .prepareMemoryProposal(
                call,
                assistantId,
                request.selectedAgentId,
                request.allowedTools,
              );
          if (pendingProposal == null) {
            throw StateError('The memory proposal could not be prepared.');
          }
        } on Object catch (error) {
          results.add(_toolErrorResult(call, error.toString(), results.length));
        }
        continue;
      }
      if (pendingProposal != null) {
        results.add(
          _toolErrorResult(
            call,
            'Tool call was not executed while a memory proposal awaits confirmation.',
            results.length,
          ),
        );
        continue;
      }
      try {
        final output = await runtime.executeTool(call, request.allowedTools);
        results.add(_toolResult(call, output, results.length));
      } on Object catch (error) {
        results.add(_toolErrorResult(call, error.toString(), results.length));
      }
    }
    conversation = _conversationById(request.conversationId)!;
    await _persistAndPublish(
      conversation.copyWith(
        updatedAt: DateTime.now(),
        messages: [...conversation.messages, ...results],
        pendingMemoryProposal: pendingProposal,
      ),
    );
    return pendingProposal == null;
  }

  ChatMessage _toolResult(ChatToolCall call, String content, int index) {
    final now = DateTime.now();
    return ChatMessage(
      id: '${now.microsecondsSinceEpoch}-tool-$index',
      role: ChatRole.tool,
      content: content,
      createdAt: now,
      toolCallId: call.id,
    );
  }

  ChatMessage _toolErrorResult(ChatToolCall call, String error, int index) =>
      _toolResult(call, jsonEncode({'ok': false, 'error': error}), index);

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

  static String _friendlyError(DioException error) => switch (error.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout =>
      'The endpoint timed out. Check the address and try again.',
    DioExceptionType.connectionError =>
      'Could not connect to the endpoint. Check the network and address.',
    DioExceptionType.badResponse =>
      'Endpoint returned HTTP ${error.response?.statusCode}. Check the model and API key.',
    _ => 'The request failed. You can retry the interrupted response.',
  };
}

class _ToolCallBuffer {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();

  void append(ChatToolCallDelta delta) {
    if (delta.id.isNotEmpty) id = delta.id;
    if (delta.name.isNotEmpty) name = delta.name;
    arguments.write(delta.arguments);
  }

  ChatToolCall build() {
    if (id.isEmpty || name.isEmpty) {
      throw const FormatException('Incomplete tool call');
    }
    return ChatToolCall(id: id, name: name, arguments: arguments.toString());
  }
}
