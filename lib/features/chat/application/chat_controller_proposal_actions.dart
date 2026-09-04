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

  Future<void> confirmPendingWorkspaceProposal() async {
    final conversation = state.requireValue.activeConversation;
    final proposal = conversation?.pendingWorkspaceProposal;
    if (conversation == null ||
        proposal == null ||
        proposal.status == WorkspaceProposalStatus.executing) {
      return;
    }
    state = AsyncData(
      state.requireValue.copyWith(
        confirmingWorkspaceToolCallId: proposal.toolCallId,
        clearError: true,
      ),
    );
    PendingWorkspaceProposal? claimed;
    WorkspaceBinding? binding;
    WorkspaceMutationCoordinator? coordinator;
    String? claimToken;
    try {
      final policy = await _selectedToolPolicy();
      final runtime = ref.read(chatToolRuntimeRegistryProvider);
      await runtime.revalidateWorkspacePermission(
        proposal: proposal,
        selectedAgentId: policy.agentId,
        allowedTools: policy.allowedTools,
      );
      binding = await WorkspaceStore(
        repository: ref.read(memoryRepositoryProvider),
      ).restoreBinding(proposal.workspaceBindingSnapshot);
      final boundary = createChatWorkspaceBoundary(
        binding,
        proposal.sessionKey,
        ref.read(memoryRepositoryProvider),
      );
      final currentRootIdentity = await boundary.rootIdentity();
      if (proposal.workspaceBindingSnapshot.rootIdentity !=
          currentRootIdentity) {
        throw StateError('workspace_binding_changed');
      }
      coordinator = WorkspaceMutationCoordinator(
        rootIdentity: currentRootIdentity,
        sessionKey: proposal.sessionKey,
        boundary: boundary,
        journal: HiveWorkspaceRecoveryJournal(),
      );
      final authoritative = ref
          .read(conversationStoreProvider)
          .loadById(conversation.id);
      if (authoritative == null ||
          authoritative.pendingWorkspaceProposal?.hasSameIdentity(proposal) !=
              true ||
          !workspaceProposalBelongsToConversation(proposal, authoritative)) {
        throw StateError('workspace_proposal_not_pending');
      }
      claimToken = await coordinator.beginClaim(
        proposal.identity,
        proposal.workspaceBindingSnapshot,
        proposal.context.ownerToken,
      );
      claimed = proposal.executing(claimToken);
      final executing = claimed;
      final saved = await _persistMutation(conversation.id, (latest) {
        final current = latest.pendingWorkspaceProposal;
        if (current == null ||
            current.status != WorkspaceProposalStatus.pending ||
            !current.hasSameIdentity(proposal) ||
            !workspaceProposalBelongsToConversation(proposal, latest)) {
          return null;
        }
        return latest.copyWith(pendingWorkspaceProposal: executing);
      });
      if (saved == null) {
        await coordinator.abandonClaim(
          proposal.identity,
          claimToken,
          proposal.context.ownerToken,
        );
        return;
      }
      final result = await coordinator.commit(
        identity: executing.identity,
        ownerToken: executing.context.ownerToken,
        proposedContent: executing.proposedContent,
        expiresAt: executing.expiresAt,
        claimToken: claimToken,
        revalidateAuthorization: () async {
          final latest = ref
              .read(conversationStoreProvider)
              .loadById(conversation.id);
          if (latest == null ||
              latest.pendingWorkspaceProposal?.hasSameIdentity(executing) !=
                  true ||
              !workspaceProposalBelongsToConversation(executing, latest)) {
            throw StateError('workspace_proposal_not_pending');
          }
          final currentPolicy = await _selectedToolPolicy();
          await runtime.revalidateWorkspacePermission(
            proposal: executing,
            selectedAgentId: currentPolicy.agentId,
            allowedTools: currentPolicy.allowedTools,
          );
        },
      );
      if (result.outcome == WorkspaceMutationOutcome.indeterminate) {
        throw const WorkspaceRecoveryPendingException(
          'workspace_recovery_pending',
        );
      }
      await _lifecycle
          .currentCoordinator(ref.read(memoryLocationRevisionProvider))
          .continueAfterWorkspaceDecision(
            conversation: saved,
            proposal: executing,
            toolResult: jsonEncode(result.payload),
            workspaceBinding: binding,
            afterPersist: () => coordinator!.acknowledgeOutcome(
              result.operationId,
              result.token,
            ),
          );
    } on Object catch (error) {
      final saved = claimed == null
          ? null
          : state.requireValue.conversationById(conversation.id);
      final executing = claimed;
      final recoveryBlocked = await _hasDurableWorkspaceOperation(executing);
      if (!recoveryBlocked && claimToken != null && coordinator != null) {
        try {
          await coordinator.abandonClaim(
            proposal.identity,
            claimToken,
            proposal.context.ownerToken,
          );
        } on Object {
          _setError('chat.workspaceConfirmError'.tr());
          return;
        }
      }
      if (!recoveryBlocked &&
          error is WorkspaceBoundaryException &&
          error.code == 'permission_changed' &&
          executing != null &&
          saved?.pendingWorkspaceProposal?.hasSameIdentity(executing) == true) {
        await _persistMutation(conversation.id, (latest) {
          final current = latest.pendingWorkspaceProposal;
          if (current == null || !current.hasSameIdentity(executing)) {
            return null;
          }
          return latest.copyWith(pendingWorkspaceProposal: executing.pending());
        });
        _setError('chat.workspaceConfirmError'.tr());
        return;
      }
      if (recoveryBlocked) {
        _setError('chat.workspaceConfirmError'.tr());
      } else if (executing != null &&
          saved?.pendingWorkspaceProposal?.hasSameIdentity(executing) == true) {
        await _lifecycle
            .currentCoordinator(ref.read(memoryLocationRevisionProvider))
            .continueAfterWorkspaceDecision(
              conversation: saved!,
              proposal: executing,
              toolResult: jsonEncode({
                'ok': false,
                'error_code': 'workspace_confirmation_failed',
              }),
              workspaceBinding: binding,
              continueStreaming: binding != null,
            );
      } else {
        _setError('chat.workspaceConfirmError'.tr());
      }
    } finally {
      if (state.hasValue) {
        state = AsyncData(
          state.requireValue.copyWith(clearConfirmingWorkspace: true),
        );
      }
    }
  }

  Future<bool> _hasDurableWorkspaceOperation(
    PendingWorkspaceProposal? proposal,
  ) async {
    if (proposal == null) return false;
    final journal = HiveWorkspaceRecoveryJournal();
    return journal.snapshot().containsKey(proposal.identity.journalKey);
  }

  Future<void> rejectPendingWorkspaceProposal() async {
    final conversation = state.requireValue.activeConversation;
    final proposal = conversation?.pendingWorkspaceProposal;
    if (conversation == null ||
        proposal == null ||
        proposal.status != WorkspaceProposalStatus.pending) {
      return;
    }
    try {
      WorkspaceBinding? binding;
      try {
        binding = await WorkspaceStore(
          repository: ref.read(memoryRepositoryProvider),
        ).restoreBinding(proposal.workspaceBindingSnapshot);
      } on Object {
        // Rejection is still terminally recorded, but never continues against
        // a newly captured or changed workspace.
      }
      await _lifecycle
          .currentCoordinator(ref.read(memoryLocationRevisionProvider))
          .continueAfterWorkspaceDecision(
            conversation: conversation,
            proposal: proposal,
            toolResult: jsonEncode({
              'ok': false,
              'error_code': 'user_rejected',
            }),
            workspaceBinding: binding,
            continueStreaming: binding != null,
          );
    } on Object {
      _setError('chat.workspaceRejectError'.tr());
    }
  }
}
