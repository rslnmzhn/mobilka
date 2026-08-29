import '../../memory/application/workspace_paths.dart';
import '../domain/conversation.dart';
import 'conversation_mutation.dart';
import 'skill_proposal_service.dart';

class SkillProposalControllerActions {
  const SkillProposalControllerActions({required this.persistMutation});
  final PersistConversationMutation persistMutation;

  Future<bool> confirm({
    required Conversation conversation,
    required String? selectedAgentId,
    required Set<String> allowedTools,
    required WorkspaceStore workspace,
  }) async {
    final proposal = conversation.pendingSkillProposal;
    if (proposal == null) return false;
    final snapshot = proposal.workspaceBindingSnapshot;
    if (snapshot == null) {
      throw StateError('Legacy workspace proposal cannot be confirmed');
    }
    final binding = await workspace.restoreBinding(snapshot);
    return SkillProposalService(persistMutation: persistMutation).confirm(
      conversation: conversation,
      proposal: proposal,
      selectedAgentId: selectedAgentId,
      allowedTools: allowedTools,
      workspaceSnapshot: binding.permissionSnapshot,
      workspaceBinding: binding,
    );
  }

  Future<bool> reject(Conversation conversation) {
    final proposal = conversation.pendingSkillProposal;
    if (proposal == null) return Future.value(false);
    return SkillProposalService(
      persistMutation: persistMutation,
    ).reject(conversation, proposal);
  }
}
