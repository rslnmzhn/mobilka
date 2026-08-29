import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import '../domain/pending_memory_proposal.dart';
import 'chat_stream_request.dart';
import 'conversation_mutation.dart';
import 'pending_workspace_binding_store.dart';

class MemoryDecisionContinuation {
  const MemoryDecisionContinuation({
    required this.conversationById,
    required this.persistMutation,
    required this.workspaceBindings,
    required this.run,
  });

  final Conversation? Function(String id) conversationById;
  final PersistConversationMutation persistMutation;
  final PendingWorkspaceBindingStore workspaceBindings;
  final Future<void> Function(ChatStreamRequest request) run;

  Future<void> continueRequest({
    required Conversation conversation,
    required PendingMemoryProposal proposal,
    required String toolResult,
  }) async {
    final requestId = conversation.pendingRequestMessageId;
    if (requestId == null) return;
    final current = conversationById(conversation.id)?.pendingMemoryProposal;
    if (current == null || !current.hasSameIdentity(proposal)) return;
    final now = DateTime.now();
    final assistantId = '${now.microsecondsSinceEpoch}-assistant';
    final retained = workspaceBindings.resolveForDecision(
      conversationId: conversation.id,
      requestMessageId: requestId,
      proposal: proposal,
    );
    final updated = await persistMutation(conversation.id, (latest) {
      final pending = latest.pendingMemoryProposal;
      if (latest.pendingRequestMessageId != requestId ||
          pending == null ||
          !pending.hasSameIdentity(proposal)) {
        return null;
      }
      final messages = _continuedMessages(
        latest.messages,
        proposal,
        toolResult,
        now,
        assistantId,
      );
      return latest.copyWith(
        updatedAt: now,
        clearPendingMemoryProposal: true,
        messages: messages,
      );
    });
    if (updated == null) return;
    await run(
      buildChatStreamRequest(
        updated,
        requestId,
        assistantId,
        selectedAgentId: proposal.selectedAgentId,
        allowedTools: proposal.allowedTools,
        workspaceBinding: retained,
      ),
    );
  }

  List<ChatMessage> _continuedMessages(
    List<ChatMessage> current,
    PendingMemoryProposal proposal,
    String toolResult,
    DateTime now,
    String assistantId,
  ) {
    final messages = [...current];
    final proposalIndex = messages.indexWhere(
      (message) => message.id == proposal.assistantMessageId,
    );
    final insertion = proposalIndex < 0
        ? messages.length
        : proposalIndex + 1 + proposal.callOccurrence;
    messages.insert(
      insertion.clamp(0, messages.length),
      ChatMessage(
        id: '${now.microsecondsSinceEpoch}-tool',
        role: ChatRole.tool,
        content: toolResult,
        createdAt: now,
        toolCallId: proposal.toolCallId,
      ),
    );
    messages.add(
      ChatMessage(
        id: assistantId,
        role: ChatRole.assistant,
        content: '',
        createdAt: now,
        status: ChatMessageStatus.pending,
      ),
    );
    return messages;
  }
}
