import '../../memory/application/workspace_paths.dart';
import '../domain/pending_workspace_proposal.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import 'chat_stream_request.dart';
import 'conversation_mutation.dart';

final class WorkspaceDecisionContinuation {
  const WorkspaceDecisionContinuation({
    required this.persistMutation,
    required this.run,
  });

  final PersistConversationMutation persistMutation;
  final Future<void> Function(ChatStreamRequest request) run;

  Future<void> continueRequest({
    required Conversation conversation,
    required PendingWorkspaceProposal proposal,
    required String toolResult,
    required WorkspaceBinding? workspaceBinding,
    required bool continueStreaming,
    required Future<void> Function()? afterPersist,
  }) async {
    final requestId = conversation.pendingRequestMessageId;
    if (requestId != proposal.requestId) return;
    final now = DateTime.now();
    final assistantId = '${now.microsecondsSinceEpoch}-assistant';
    final updated = await persistMutation(conversation.id, (latest) {
      final pending = latest.pendingWorkspaceProposal;
      if (latest.pendingRequestMessageId != requestId ||
          pending == null ||
          !pending.hasSameIdentity(proposal)) {
        return null;
      }
      final messages = [...latest.messages];
      _insertToolResult(messages, proposal, toolResult, now);
      if (continueStreaming) {
        messages.add(
          ChatMessage(
            id: assistantId,
            role: ChatRole.assistant,
            content: '',
            createdAt: now,
            status: ChatMessageStatus.pending,
          ),
        );
      }
      return latest.copyWith(
        updatedAt: now,
        clearPendingWorkspaceProposal: true,
        messages: messages,
      );
    });
    if (updated == null) return;
    await afterPersist?.call();
    if (!continueStreaming) return;
    await run(
      buildChatStreamRequest(
        updated,
        requestId!,
        assistantId,
        selectedAgentId: proposal.selectedAgentId,
        allowedTools: proposal.allowedTools,
        workspaceBinding: workspaceBinding,
      ),
    );
  }

  void _insertToolResult(
    List<ChatMessage> messages,
    PendingWorkspaceProposal proposal,
    String toolResult,
    DateTime now,
  ) {
    final sourceIndex = messages.indexWhere(
      (message) => message.id == proposal.assistantMessageId,
    );
    final source = sourceIndex < 0 ? null : messages[sourceIndex];
    final following = sourceIndex < 0
        ? const <ChatMessage>[]
        : messages
              .skip(sourceIndex + 1)
              .takeWhile((message) => message.role == ChatRole.tool)
              .toList();
    final insertion = sourceIndex < 0
        ? messages.length
        : sourceIndex + 1 + following.length;
    messages.insert(
      insertion.clamp(0, messages.length),
      ChatMessage(
        id: '${now.microsecondsSinceEpoch}-workspace-tool',
        role: ChatRole.tool,
        content: toolResult,
        createdAt: now,
        toolCallId: proposal.toolCallId,
        toolCallIndex: proposal.toolCallIndex,
      ),
    );
    if (source == null) return;
    final start = sourceIndex + 1;
    final end = start + following.length + 1;
    final ordered = messages.sublist(start, end)
      ..sort(
        (first, second) => _toolResultOrdinal(
          source,
          first,
        ).compareTo(_toolResultOrdinal(source, second)),
      );
    messages.replaceRange(start, end, ordered);
  }

  int _toolResultOrdinal(ChatMessage assistant, ChatMessage result) {
    final persisted = result.toolCallIndex;
    if (persisted != null) return persisted;
    var occurrence = 0;
    for (var index = 0; index < assistant.toolCalls.length; index++) {
      final call = assistant.toolCalls[index];
      if (call.id != result.toolCallId) continue;
      final prior = assistant.toolCalls
          .take(index)
          .where((candidate) => candidate.id == call.id)
          .length;
      if (prior == occurrence) return index;
      occurrence++;
    }
    return assistant.toolCalls.length;
  }
}
