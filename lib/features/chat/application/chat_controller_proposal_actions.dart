// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'chat_controller.dart';

extension ChatControllerProposalActions on ChatController {
  Future<void> confirmPendingMemoryProposal() async {
    final conversation = state.requireValue.activeConversation;
    final proposal = conversation?.pendingMemoryProposal;
    if (proposal != null) {
      state = AsyncData(
        state.requireValue.copyWith(
          confirmingMemoryToolCallId: proposal.toolCallId,
          clearError: true,
        ),
      );
    }
    try {
      _applyMemoryDecisionAction(
        await _memoryDecisionService.confirm(
          conversation: conversation,
          proposal: proposal,
        ),
      );
    } finally {
      if (proposal != null &&
          state.hasValue &&
          state.requireValue.confirmingMemoryToolCallId ==
              proposal.toolCallId) {
        state = AsyncData(
          state.requireValue.copyWith(clearConfirmingMemory: true),
        );
      }
    }
  }

  Future<void> rejectPendingMemoryProposal() async {
    final conversation = state.requireValue.activeConversation;
    final proposal = conversation?.pendingMemoryProposal;
    if (conversation == null || proposal == null) return;
    _applyMemoryDecisionAction(
      await _memoryDecisionService.reject(
        conversation: conversation,
        proposal: proposal,
      ),
    );
  }

  Future<void> confirmPendingToolProposal() async {
    final conversation = state.requireValue.activeConversation;
    final proposal = conversation?.pendingToolProposal;
    if (conversation == null || proposal == null || proposal.claimed) return;
    state = AsyncData(
      state.requireValue.copyWith(confirmingToolCallId: proposal.call.id),
    );
    try {
      final runtime = ref.read(chatToolRuntimeRegistryProvider);
      final selected = (await ref.read(
        agentsControllerProvider.future,
      )).selected;
      final binding = _captureWorkspaceBinding();
      final allowed = selected?.definition.tools.toSet() ?? const <String>{};
      final definitions = await runtime.availableTools(allowed);
      await GenericToolConfirmationService(
        persistMutation: _persistMutation,
      ).confirm(
        conversation: conversation,
        proposal: proposal,
        selectedAgentId: selected?.definition.id,
        currentAllowedTools: allowed,
        definition: definitions
            .where((item) => item.name == proposal.call.name)
            .firstOrNull,
        workspaceSnapshot: binding?.permissionSnapshot,
        execute: () => runtime.executeTool(
          proposal.call,
          proposal.allowedTools,
          context: ChatToolExecutionContext(
            conversationId: conversation.id,
            sessionKey: conversation.sessionKey,
            workspaceBinding: binding,
          ),
        ),
      );
    } finally {
      if (state.hasValue) {
        state = AsyncData(
          state.requireValue.copyWith(clearConfirmingTool: true),
        );
      }
    }
  }

  Future<void> rejectPendingToolProposal() async {
    final conversation = state.requireValue.activeConversation;
    final proposal = conversation?.pendingToolProposal;
    if (conversation == null || proposal == null) return;
    await GenericToolConfirmationService(
      persistMutation: _persistMutation,
    ).reject(conversation: conversation, proposal: proposal);
  }

  Future<void> confirmPendingSkillProposal() async {
    final conversation = state.requireValue.activeConversation;
    final proposal = conversation?.pendingSkillProposal;
    if (conversation == null || proposal == null) return;
    state = AsyncData(
      state.requireValue.copyWith(confirmingSkillName: proposal.name),
    );
    try {
      final policy = await _selectedToolPolicy();
      await SkillProposalControllerActions(
        persistMutation: _persistMutation,
      ).confirm(
        conversation: conversation,
        selectedAgentId: policy.agentId,
        allowedTools: policy.allowedTools,
        workspace: WorkspaceStore(
          repository: ref.read(memoryRepositoryProvider),
        ),
      );
    } finally {
      if (state.hasValue) {
        state = AsyncData(
          state.requireValue.copyWith(clearConfirmingSkill: true),
        );
      }
    }
  }

  Future<void> rejectPendingSkillProposal() async {
    final conversation = state.requireValue.activeConversation;
    if (conversation?.pendingSkillProposal == null) return;
    await SkillProposalControllerActions(
      persistMutation: _persistMutation,
    ).reject(conversation!);
  }
}
