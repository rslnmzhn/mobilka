import '../domain/chat_message.dart';
import '../domain/chat_tool.dart';
import '../domain/conversation.dart';
import '../domain/pending_tool_proposal.dart';
import 'conversation_mutation.dart';
import 'chat_tool_effect_policy.dart';

class GenericToolConfirmationService {
  const GenericToolConfirmationService({required this.persistMutation});

  final PersistConversationMutation persistMutation;

  Future<bool> confirm({
    required Conversation conversation,
    required PendingToolProposal proposal,
    required String? selectedAgentId,
    required Set<String> currentAllowedTools,
    required ChatToolDefinition? definition,
    required String? workspaceSnapshot,
    required Future<String> Function() execute,
  }) async {
    _validate(
      conversation: conversation,
      proposal: proposal,
      selectedAgentId: selectedAgentId,
      currentAllowedTools: currentAllowedTools,
      definition: definition,
      workspaceSnapshot: workspaceSnapshot,
    );
    final claimed = proposal.claim();
    final claim = await persistMutation(conversation.id, (latest) {
      final current = latest.pendingToolProposal;
      if (current == null ||
          current.claimed ||
          !current.hasSameIdentity(proposal)) {
        return null;
      }
      return latest.copyWith(pendingToolProposal: claimed);
    });
    if (claim == null) return false;
    String output;
    try {
      output = await execute();
    } on Object {
      output = '{"ok":false,"error_code":"tool_execution_failed"}';
    }
    return _complete(conversation.id, claimed, output);
  }

  Future<bool> reject({
    required Conversation conversation,
    required PendingToolProposal proposal,
  }) => _complete(
    conversation.id,
    proposal,
    '{"ok":false,"error_code":"user_rejected"}',
  );

  void _validate({
    required Conversation conversation,
    required PendingToolProposal proposal,
    required String? selectedAgentId,
    required Set<String> currentAllowedTools,
    required ChatToolDefinition? definition,
    required String? workspaceSnapshot,
  }) {
    final persisted = conversation.pendingToolProposal;
    if (persisted == null ||
        !persisted.hasSameIdentity(proposal) ||
        proposal.conversationId != conversation.id ||
        proposal.requestId != conversation.pendingRequestMessageId ||
        !proposal.sourceTainted ||
        selectedAgentId != proposal.selectedAgentId ||
        !proposal.allowedTools.contains(proposal.call.name) ||
        !currentAllowedTools.contains(proposal.call.name) ||
        proposal.permissionSnapshot != workspaceSnapshot ||
        resolveChatToolEffect(definition, proposal.call) != proposal.effect ||
        proposal.effect == ChatToolEffect.readOnly ||
        proposal.effect == ChatToolEffect.runtimeConfirmed) {
      throw StateError('Tool proposal authorization changed');
    }
  }

  Future<bool> _complete(
    String conversationId,
    PendingToolProposal proposal,
    String output,
  ) async {
    final completed = await persistMutation(conversationId, (latest) {
      final current = latest.pendingToolProposal;
      if (current == null || !current.hasSameIdentity(proposal)) return null;
      final now = DateTime.now();
      return latest.copyWith(
        updatedAt: now,
        clearPendingToolProposal: true,
        clearPendingRequest: true,
        messages: [
          ...latest.messages,
          ChatMessage(
            id: '${now.microsecondsSinceEpoch}-tool-confirmed',
            role: ChatRole.tool,
            content: output,
            createdAt: now,
            toolCallId: proposal.call.id,
          ),
        ],
      );
    });
    return completed != null;
  }
}
