import '../../memory/application/skill_content_policy.dart';
import '../../memory/application/skills_chat_tools.dart';
import '../../memory/application/workspace_paths.dart';
import '../../memory/data/memory_file_store_contracts.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import '../domain/pending_skill_proposal.dart';
import 'conversation_mutation.dart';

class SkillProposalService {
  const SkillProposalService({required this.persistMutation});

  final PersistConversationMutation persistMutation;

  Future<bool> confirm({
    required Conversation conversation,
    required PendingSkillProposal proposal,
    required String? selectedAgentId,
    required Set<String> allowedTools,
    required String? workspaceSnapshot,
    required WorkspaceBinding workspaceBinding,
  }) async {
    if (DateTime.now().toUtc().difference(proposal.createdAt.toUtc()) >
        const Duration(hours: 24)) {
      throw StateError('Skill proposal expired');
    }
    if (proposal.state != PendingSkillProposalState.pending ||
        conversation.pendingSkillProposal?.sameIdentity(proposal) != true ||
        selectedAgentId != proposal.selectedAgentId ||
        !allowedTools.contains(SkillsChatTools.proposeSkill.name) ||
        workspaceSnapshot != proposal.permissionSnapshot) {
      throw StateError('Skill proposal authorization changed');
    }
    const SkillContentPolicy().validate(proposal.proposedContent);
    if (workspaceBinding.permissionSnapshot != proposal.permissionSnapshot) {
      throw StateError('Bound workspace changed');
    }
    final claimed = proposal.claim();
    final claim = await persistMutation(conversation.id, (latest) {
      if (latest.pendingSkillProposal?.sameIdentity(proposal) != true) {
        return null;
      }
      return latest.copyWith(pendingSkillProposal: claimed);
    });
    if (claim == null) return false;
    final result = await workspaceBinding.commitSkillCandidate(
      name: '${proposal.name}.md',
      content: proposal.proposedContent,
      expectedHash: proposal.expectedHash,
      maxCount: SkillsChatTools.defaultMaxSkillCount,
      maxTotalBytes: SkillsChatTools.defaultMaxTotalSkillBytes,
    );
    await _finish(
      conversation.id,
      claimed,
      result == SkillCommitResult.written
          ? 'skill_saved'
          : 'skill_update_conflict',
    );
    return result == SkillCommitResult.written;
  }

  Future<bool> reject(
    Conversation conversation,
    PendingSkillProposal proposal,
  ) => _finish(conversation.id, proposal, 'skill_proposal_rejected');

  Future<bool> _finish(
    String conversationId,
    PendingSkillProposal proposal,
    String status,
  ) async {
    final updated = await persistMutation(conversationId, (latest) {
      final current = latest.pendingSkillProposal;
      final matches =
          current?.sameIdentity(proposal) == true ||
          (proposal.state == PendingSkillProposalState.pending &&
              current?.sameIdentity(proposal.claim()) == true);
      if (!matches) return null;
      final now = DateTime.now();
      return latest.copyWith(
        clearPendingSkillProposal: true,
        updatedAt: now,
        messages: [
          ...latest.messages,
          ChatMessage(
            id: '${now.microsecondsSinceEpoch}-skill-status',
            role: ChatRole.system,
            content: status,
            createdAt: now,
          ),
        ],
      );
    });
    return updated != null;
  }
}
