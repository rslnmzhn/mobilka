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
    if (!await _prepare(request, assistantId, calls)) return false;
    final state = _ToolExecutionState(
      context: _executionContext(request, cancellation),
    );
    for (final indexedCall in calls.indexed) {
      await _dispatchCall(
        request,
        assistantId,
        calls,
        indexedCall.$1,
        state,
        securityState,
      );
    }
    if (!await _persistResults(request, assistantId, state)) return false;
    if (state.budgetExceeded) {
      throw const PublicSourceFailure('conversation_wire_budget_exceeded');
    }
    if (state.memoryProposal != null) {
      _onPendingMemoryProposal?.call(state.memoryProposal!);
    }
    return state.memoryProposal == null && state.toolProposal == null;
  }

  Future<bool> _prepare(
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
    return true;
  }

  ChatToolExecutionContext _executionContext(
    ChatStreamRequest request,
    ChatToolCancellation? cancellation,
  ) {
    return ChatToolExecutionContext(
      conversationId: request.conversationId,
      sessionKey: request.sessionKey,
      workspaceBinding: request.workspaceBinding,
      cancellation: cancellation,
      consumePublicSourceWireBytes: (bytes) =>
          _consumeWireBytes(request, bytes),
      reservePublicSourceWireBytes: (maximum) =>
          _reserveWireBytes(request, maximum),
      refundPublicSourceWireBytes: (unused) =>
          _refundWireBytes(request, unused),
    );
  }

  Future<void> _dispatchCall(
    ChatStreamRequest request,
    String assistantId,
    List<ChatToolCall> calls,
    int index,
    _ToolExecutionState state,
    RequestToolSecurityState security,
  ) async {
    final call = calls[index];
    final occurrence = calls
        .take(index)
        .where((candidate) => candidate.id == call.id)
        .length;
    final definition = await _definitionFor(call, request.allowedTools);
    final effect = resolveChatToolEffect(definition, call);
    if (security.sourceTainted &&
        effect != ChatToolEffect.readOnly &&
        effect != ChatToolEffect.runtimeConfirmed) {
      _gateSourceTainted(request, assistantId, call, occurrence, effect, state);
      return;
    }
    if (_memoryDispatcher.handles(call)) {
      await _dispatchMemory(request, assistantId, call, occurrence, state);
      return;
    }
    if (state.memoryProposal != null) {
      state.addError(
        call,
        'Tool call was not executed while a memory proposal awaits confirmation.',
        this,
      );
      return;
    }
    await _executeRuntime(request, call, state, security);
  }

  void _gateSourceTainted(
    ChatStreamRequest request,
    String assistantId,
    ChatToolCall call,
    int occurrence,
    ChatToolEffect effect,
    _ToolExecutionState state,
  ) {
    state.toolProposal ??= PendingToolProposal(
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
    if (state.toolProposal!.call.id != call.id) {
      state.addError(call, 'confirmation_pending', this);
    }
  }

  Future<void> _dispatchMemory(
    ChatStreamRequest request,
    String assistantId,
    ChatToolCall call,
    int occurrence,
    _ToolExecutionState state,
  ) async {
    if (state.memoryProposal != null) {
      state.addError(
        call,
        'Only one memory proposal can be active per response.',
        this,
      );
      return;
    }
    final dispatched = await _memoryDispatcher.dispatch(
      runtime: runtime,
      call: call,
      assistantId: assistantId,
      selectedAgentId: request.selectedAgentId,
      allowedTools: request.allowedTools,
      occurrence: occurrence,
      resultIndex: state.results.length,
    );
    state.memoryProposal = dispatched.proposal;
    if (dispatched.result != null) state.results.add(dispatched.result!);
  }

  Future<void> _executeRuntime(
    ChatStreamRequest request,
    ChatToolCall call,
    _ToolExecutionState state,
    RequestToolSecurityState security,
  ) async {
    try {
      final output = await runtime.executeTool(
        call,
        request.allowedTools,
        context: state.context,
      );
      state.results.add(_toolResult(call, output, state.results.length));
      final succeeded = _isSuccessful(output);
      await security.recordOutcome(toolName: call.name, succeeded: succeeded);
    } on FormatException catch (error) {
      await _recordFailure(request, call, error.message, state, security);
    } on PublicSourceFailure catch (error) {
      if (error.code == 'conversation_wire_budget_exceeded') {
        state.budgetExceeded = true;
      }
      await _recordUnexpectedFailure(request, call, error, state, security);
    } on Object catch (error) {
      await _recordUnexpectedFailure(request, call, error, state, security);
    }
  }

  Future<void> _recordFailure(
    ChatStreamRequest request,
    ChatToolCall call,
    String message,
    _ToolExecutionState state,
    RequestToolSecurityState security,
  ) async {
    await security.recordOutcome(toolName: call.name, succeeded: false);
    state.addError(call, message, this);
  }

  Future<void> _recordUnexpectedFailure(
    ChatStreamRequest request,
    ChatToolCall call,
    Object error,
    _ToolExecutionState state,
    RequestToolSecurityState security,
  ) async {
    await _recordFailure(request, call, unexpectedToolError, state, security);
    _logger?.log(
      event: 'tool.execution',
      level: AppLogLevel.error,
      conversationId: request.conversationId,
      toolCallId: call.id,
      status: 'failed',
      error: error,
    );
  }

  Future<bool> _persistResults(
    ChatStreamRequest request,
    String assistantId,
    _ToolExecutionState state,
  ) async {
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
          ...state.results,
        ],
        pendingMemoryProposal: state.memoryProposal,
        pendingToolProposal: state.toolProposal,
      );
    });
    if (persisted == null ||
        persisted.pendingRequestMessageId != request.requestMessageId) {
      return false;
    }
    return true;
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

class _ToolExecutionState {
  _ToolExecutionState({required this.context});

  final ChatToolExecutionContext context;
  final results = <ChatMessage>[];
  PendingMemoryProposal? memoryProposal;
  PendingToolProposal? toolProposal;
  var budgetExceeded = false;

  void addError(ChatToolCall call, String message, ChatToolExecutor executor) {
    results.add(executor._toolErrorResult(call, message, results.length));
  }
}
