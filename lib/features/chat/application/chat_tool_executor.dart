import 'dart:convert';

import '../../../core/logging/app_logger.dart';
import '../../../features/memory/application/instant_memory_writer.dart';
import '../../../features/memory/application/persona_registry.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import '../domain/pending_memory_proposal.dart';
import 'chat_stream_request.dart';
import 'chat_tool_runtime.dart';
import 'memory_tool_dispatcher.dart';
import 'conversation_mutation.dart';

class ChatToolExecutor {
  ChatToolExecutor({
    required this.runtime,
    required this.conversationById,
    required this.persistMutation,
    InstantMemoryWriter? instantMemoryWriter,
    PersonaRegistryAdapter? personaRegistry,
    AppLogger? logger,
    void Function(PendingMemoryProposal proposal)? onPendingMemoryProposal,
  }) : _memoryDispatcher = MemoryToolDispatcher(
         instantMemoryWriter: instantMemoryWriter,
         personaRegistry: personaRegistry,
         logger: logger,
       ),
       _logger = logger,
       _onPendingMemoryProposal = onPendingMemoryProposal;

  final ChatToolRuntime runtime;
  final Conversation? Function(String id) conversationById;
  final PersistConversationMutation persistMutation;
  final MemoryToolDispatcher _memoryDispatcher;
  final AppLogger? _logger;
  final void Function(PendingMemoryProposal proposal)? _onPendingMemoryProposal;

  static const unexpectedToolError = 'Tool execution failed unexpectedly';

  Future<bool> execute(
    ChatStreamRequest request,
    String assistantId,
    List<ChatToolCall> calls,
  ) async {
    final prepared = await persistMutation(request.conversationId, (latest) {
      if (latest.pendingRequestMessageId != request.requestMessageId) {
        return null;
      }
      return latest.copyWith(
        updatedAt: DateTime.now(),
        messages: latest.messages
            .map(
              (message) => message.id == assistantId
                  ? message.copyWith(
                      status: ChatMessageStatus.streaming,
                      toolCalls: calls,
                    )
                  : message,
            )
            .toList(),
      );
    });
    if (prepared == null ||
        prepared.pendingRequestMessageId != request.requestMessageId) {
      return false;
    }
    PendingMemoryProposal? pendingProposal;
    final results = <ChatMessage>[];
    final executionContext = ChatToolExecutionContext(
      conversationId: request.conversationId,
      sessionKey: request.sessionKey,
      workspaceBinding: request.workspaceBinding,
    );
    for (final indexedCall in calls.indexed) {
      final call = indexedCall.$2;
      final occurrence = calls
          .take(indexedCall.$1)
          .where((candidate) => candidate.id == call.id)
          .length;
      if (_memoryDispatcher.handles(call)) {
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
        final dispatched = await _memoryDispatcher.dispatch(
          runtime: runtime,
          call: call,
          assistantId: assistantId,
          selectedAgentId: request.selectedAgentId,
          allowedTools: request.allowedTools,
          occurrence: occurrence,
          resultIndex: results.length,
        );
        pendingProposal = dispatched.proposal;
        if (dispatched.result != null) results.add(dispatched.result!);
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
        final output = await runtime.executeTool(
          call,
          request.allowedTools,
          context: executionContext,
        );
        results.add(_toolResult(call, output, results.length));
      } on FormatException catch (error) {
        results.add(_toolErrorResult(call, error.message, results.length));
      } on Object catch (error) {
        _logger?.log(
          event: 'tool.execution',
          level: AppLogLevel.error,
          conversationId: request.conversationId,
          toolCallId: call.id,
          status: 'failed',
          error: error,
        );
        results.add(
          _toolErrorResult(call, unexpectedToolError, results.length),
        );
      }
    }
    final persisted = await persistMutation(request.conversationId, (latest) {
      if (latest.pendingRequestMessageId != request.requestMessageId) {
        return null;
      }
      return latest.copyWith(
        updatedAt: DateTime.now(),
        messages: [
          ...latest.messages.map(
            (message) => message.id == assistantId
                ? message.copyWith(status: ChatMessageStatus.complete)
                : message,
          ),
          ...results,
        ],
        pendingMemoryProposal: pendingProposal,
      );
    });
    if (persisted == null ||
        persisted.pendingRequestMessageId != request.requestMessageId) {
      return false;
    }
    if (pendingProposal != null) {
      _onPendingMemoryProposal?.call(pendingProposal);
    }
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
}
