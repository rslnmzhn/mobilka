import '../../memory/application/workspace_paths.dart';
import '../domain/pending_memory_proposal.dart';
import 'chat_stream_request.dart';

/// Retains request-scoped workspace authority while a memory decision is
/// pending. Streaming lifecycle decisions remain with the coordinator.
class PendingWorkspaceBindingStore {
  final Map<_WorkspaceBindingKey, WorkspaceBinding> _bindings = {};

  void retain(
    ChatStreamRequest request,
    PendingMemoryProposal proposal,
    WorkspaceBinding binding,
  ) {
    _bindings[_WorkspaceBindingKey.from(request, proposal)] = binding;
  }

  WorkspaceBinding? resolveForDecision({
    required String conversationId,
    required String requestMessageId,
    required PendingMemoryProposal proposal,
  }) =>
      _bindings[_WorkspaceBindingKey(
        conversationId: conversationId,
        requestMessageId: requestMessageId,
        assistantMessageId: proposal.assistantMessageId,
        toolCallId: proposal.toolCallId,
        callOccurrence: proposal.callOccurrence,
      )];

  WorkspaceBinding? resolveForRetry(
    String conversationId,
    String requestMessageId,
  ) {
    for (final entry in _bindings.entries) {
      if (entry.key.conversationId == conversationId &&
          entry.key.requestMessageId == requestMessageId) {
        return entry.value;
      }
    }
    return null;
  }

  void cleanupTerminal(String conversationId, String requestMessageId) {
    _bindings.removeWhere(
      (key, _) =>
          key.conversationId == conversationId &&
          key.requestMessageId == requestMessageId,
    );
  }

  void forgetConversation(String conversationId) {
    _bindings.removeWhere((key, _) => key.conversationId == conversationId);
  }

  void reset() => _bindings.clear();
}

class _WorkspaceBindingKey {
  const _WorkspaceBindingKey({
    required this.conversationId,
    required this.requestMessageId,
    required this.assistantMessageId,
    required this.toolCallId,
    required this.callOccurrence,
  });

  factory _WorkspaceBindingKey.from(
    ChatStreamRequest request,
    PendingMemoryProposal proposal,
  ) => _WorkspaceBindingKey(
    conversationId: request.conversationId,
    requestMessageId: request.requestMessageId,
    assistantMessageId: proposal.assistantMessageId,
    toolCallId: proposal.toolCallId,
    callOccurrence: proposal.callOccurrence,
  );

  final String conversationId;
  final String requestMessageId;
  final String assistantMessageId;
  final String toolCallId;
  final int callOccurrence;

  @override
  bool operator ==(Object other) =>
      other is _WorkspaceBindingKey &&
      conversationId == other.conversationId &&
      requestMessageId == other.requestMessageId &&
      assistantMessageId == other.assistantMessageId &&
      toolCallId == other.toolCallId &&
      callOccurrence == other.callOccurrence;

  @override
  int get hashCode => Object.hash(
    conversationId,
    requestMessageId,
    assistantMessageId,
    toolCallId,
    callOccurrence,
  );
}
