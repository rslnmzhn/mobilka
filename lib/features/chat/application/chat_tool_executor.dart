import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/logging/app_logger.dart';
import '../../../features/memory/application/instant_memory_writer.dart';
import '../../../features/memory/application/persona_registry.dart';
import '../../public_source/application/public_source_reader.dart';
import '../../public_source/application/public_source_policy.dart';
import '../domain/chat_message.dart';
import '../domain/chat_tool.dart';
import '../domain/conversation.dart';
import '../domain/pending_memory_proposal.dart';
import '../domain/pending_tool_proposal.dart';
import 'chat_stream_request.dart';
import 'chat_tool_runtime.dart';
import 'memory_tool_dispatcher.dart';
import 'conversation_mutation.dart';
import 'request_tool_security_state.dart';
import 'chat_tool_effect_policy.dart';

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

  @visibleForTesting
  ChatToolExecutionContext publicSourceContextForTest(
    ChatStreamRequest request,
  ) => ChatToolExecutionContext(
    conversationId: request.conversationId,
    sessionKey: request.sessionKey,
    consumePublicSourceWireBytes: (bytes) => _consumeWireBytes(request, bytes),
    reservePublicSourceWireBytes: (maximum) =>
        _reserveWireBytes(request, maximum),
    refundPublicSourceWireBytes: (unused) => _refundWireBytes(request, unused),
  );

  Future<bool> execute(
    ChatStreamRequest request,
    String assistantId,
    List<ChatToolCall> calls, {
    ChatToolCancellation? cancellation,
    required RequestToolSecurityState securityState,
  }) async {
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
    var budgetExceeded = false;
    final executionContext = ChatToolExecutionContext(
      conversationId: request.conversationId,
      sessionKey: request.sessionKey,
      workspaceBinding: request.workspaceBinding,
      cancellation: cancellation,
      consumePublicSourceWireBytes: (bytes) =>
          _consumeWireBytes(request, bytes).catchError((error) {
            if (error is PublicSourceFailure &&
                error.code == 'conversation_wire_budget_exceeded') {
              budgetExceeded = true;
            }
            throw error;
          }),
      reservePublicSourceWireBytes: (maximum) =>
          _reserveWireBytes(request, maximum),
      refundPublicSourceWireBytes: (unused) =>
          _refundWireBytes(request, unused),
    );
    PendingToolProposal? pendingToolProposal;
    for (final indexedCall in calls.indexed) {
      final call = indexedCall.$2;
      final occurrence = calls
          .take(indexedCall.$1)
          .where((candidate) => candidate.id == call.id)
          .length;
      final definition = await _definitionFor(call, request.allowedTools);
      final effect = resolveChatToolEffect(definition, call);
      if (securityState.sourceTainted &&
          effect != ChatToolEffect.readOnly &&
          effect != ChatToolEffect.runtimeConfirmed) {
        pendingToolProposal ??= PendingToolProposal(
          conversationId: request.conversationId,
          requestId: request.requestMessageId,
          assistantMessageId: assistantId,
          callOccurrence: occurrence,
          call: call,
          selectedAgentId: request.selectedAgentId,
          allowedTools: request.allowedTools,
          effect: effect,
          sourceTainted: true,
          permissionSnapshot: request.workspaceBinding?.permissionSnapshot,
          createdAt: DateTime.now(),
        );
        if (pendingToolProposal.call.id != call.id) {
          results.add(
            _toolErrorResult(call, 'confirmation_pending', results.length),
          );
        }
        continue;
      }
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
        if (call.name == 'read_public_source' && _isSuccessful(output)) {
          securityState.markSourceTainted(
            conversationId: request.conversationId,
            requestId: request.requestMessageId,
          );
        }
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
        pendingToolProposal: pendingToolProposal,
      );
    });
    if (persisted == null ||
        persisted.pendingRequestMessageId != request.requestMessageId) {
      return false;
    }
    if (budgetExceeded) {
      throw const PublicSourceFailure('conversation_wire_budget_exceeded');
    }
    if (pendingProposal != null) {
      _onPendingMemoryProposal?.call(pendingProposal);
    }
    return pendingProposal == null && pendingToolProposal == null;
  }

  Future<ChatToolDefinition?> _definitionFor(
    ChatToolCall call,
    Set<String> allowedTools,
  ) async => (await runtime.availableTools(
    allowedTools,
  )).where((definition) => definition.name == call.name).firstOrNull;

  bool _isSuccessful(String output) {
    try {
      final decoded = jsonDecode(output);
      return decoded is Map && decoded['ok'] == true;
    } on FormatException {
      return false;
    }
  }

  static bool successfulPublicSourceResult(String output) {
    try {
      final decoded = jsonDecode(output);
      return decoded is Map && decoded['ok'] == true;
    } on FormatException {
      return false;
    }
  }

  Future<void> _consumeWireBytes(ChatStreamRequest request, int bytes) async {
    var exceeded = false;
    final updated = await persistMutation(request.conversationId, (latest) {
      if (latest.pendingRequestMessageId != request.requestMessageId) {
        return null;
      }
      final total = latest.publicSourceWireBytesUsed + bytes;
      if (total > publicSourceConversationWireLimit) {
        exceeded = true;
        return latest.copyWith(
          publicSourceWireBytesUsed: publicSourceConversationWireLimit,
        );
      }
      return latest.copyWith(publicSourceWireBytesUsed: total);
    });
    if (updated == null) throw const PublicSourceFailure('cancelled');
    if (exceeded) {
      throw const PublicSourceFailure('conversation_wire_budget_exceeded');
    }
  }

  Future<int> _reserveWireBytes(ChatStreamRequest request, int maximum) async {
    var reserved = 0;
    final updated = await persistMutation(request.conversationId, (latest) {
      if (latest.pendingRequestMessageId != request.requestMessageId) {
        return null;
      }
      final used = latest.publicSourceWireBytesUsed.clamp(
        0,
        publicSourceConversationWireLimit,
      );
      reserved = (publicSourceConversationWireLimit - used).clamp(0, maximum);
      return latest.copyWith(publicSourceWireBytesUsed: used + reserved);
    });
    if (updated == null) throw const PublicSourceFailure('cancelled');
    if (reserved == 0) {
      throw const PublicSourceFailure('conversation_wire_budget_exceeded');
    }
    return reserved;
  }

  Future<void> _refundWireBytes(ChatStreamRequest request, int unused) async {
    if (unused <= 0) return;
    await persistMutation(request.conversationId, (latest) {
      final used = latest.publicSourceWireBytesUsed.clamp(
        0,
        publicSourceConversationWireLimit,
      );
      return latest.copyWith(
        publicSourceWireBytesUsed: (used - unused).clamp(0, used),
      );
    });
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
