import '../../../core/workspace/workspace_binding.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import '../domain/pending_document_proposal.dart';
import 'chat_stream_request.dart';
import 'conversation_mutation.dart';

final class DocumentDecisionContinuation {
  const DocumentDecisionContinuation({required this.persistMutation});
  final PersistConversationMutation persistMutation;

  Future<ChatStreamRequest?> continueRequest({
    required Conversation conversation,
    required PendingDocumentProposal proposal,
    required String toolResult,
    required WorkspaceBinding binding,
  }) async {
    final now = DateTime.now();
    final assistantId = '${now.microsecondsSinceEpoch}-assistant';
    final updated = await persistMutation(conversation.id, (latest) {
      if (latest.pendingDocumentProposal?.encode() != proposal.encode()) {
        return null;
      }
      final messages = [...latest.messages];
      final owner = messages.indexWhere(
        (m) => m.id == proposal.assistantMessageId,
      );
      if (owner < 0) return null;
      final segment = messages
          .skip(owner + 1)
          .takeWhile((m) => m.role == ChatRole.tool)
          .toList(growable: false);
      final relativeInsertion = segment.indexWhere(
        (message) =>
            message.toolCallIndex != null &&
            message.toolCallIndex! > proposal.toolCallIndex,
      );
      final insertion = relativeInsertion < 0
          ? owner + 1 + segment.length
          : owner + 1 + relativeInsertion;
      messages.insert(
        insertion,
        ChatMessage(
          id: '${now.microsecondsSinceEpoch}-document-tool',
          role: ChatRole.tool,
          content: toolResult,
          createdAt: now,
          toolCallId: proposal.toolCallId,
          toolCallIndex: proposal.toolCallIndex,
        ),
      );
      messages.insert(
        owner + 2 + segment.length,
        ChatMessage(
          id: assistantId,
          role: ChatRole.assistant,
          content: '',
          createdAt: now,
          status: ChatMessageStatus.pending,
        ),
      );
      return latest.copyWith(
        clearPendingDocumentProposal: true,
        messages: messages,
        updatedAt: now,
      );
    });
    if (updated == null) return null;
    return buildChatStreamRequest(
      updated,
      proposal.requestId,
      assistantId,
      selectedAgentId: proposal.selectedAgentId,
      allowedTools: proposal.allowedTools,
      workspaceBinding: binding,
    );
  }
}
