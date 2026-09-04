import 'dart:convert';

import '../../memory/data/memory_repository.dart';
import '../../workspace/application/workspace_recovery_record.dart';
import '../../workspace/application/workspace_startup_recovery_service.dart';
import '../../workspace/data/workspace_recovery_journal.dart';
import '../../workspace/domain/workspace_mutation_result.dart';
import '../domain/pending_workspace_proposal.dart';
import '../data/conversation_store.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import '../../memory/application/workspace_paths.dart';
import 'chat_workspace_boundary_factory.dart';

/// Applies pure workspace recovery outcomes to conversation-owned state.
final class ChatWorkspaceStartupRecovery {
  ChatWorkspaceStartupRecovery({
    required this.conversations,
    required this.memoryRepository,
    required this.journal,
    WorkspaceStartupRecoveryService? workspaceRecovery,
  }) : _workspaceRecovery =
           workspaceRecovery ??
           WorkspaceStartupRecoveryService(
             journal: journal,
             restoreBinding: (snapshot) => WorkspaceStore(
               repository: memoryRepository,
             ).restoreBinding(snapshot),
             boundaryFactory: (binding, sessionKey) =>
                 createChatWorkspaceBoundary(
                   binding,
                   sessionKey,
                   memoryRepository,
                 ),
           );

  final ConversationStore conversations;
  final MemoryRepository memoryRepository;
  final WorkspaceRecoveryJournal journal;
  final WorkspaceStartupRecoveryService _workspaceRecovery;

  Future<void> recover() async {
    List<WorkspaceStartupRecoveryOutcome> outcomes;
    try {
      outcomes = await _workspaceRecovery.recover();
    } on Object {
      // Workspace recovery is fail-closed, but chat history remains available.
      return;
    }
    final matched = <String>{};
    for (final outcome in outcomes) {
      final ownerToken =
          outcome.record?.ownerToken ?? outcome.invalidHint?.ownerToken;
      final conversation = _conversationForOwner(ownerToken, outcome.key);
      final proposal = conversation?.pendingWorkspaceProposal;
      final claimedByProposal =
          proposal != null &&
          (ownerToken != null
              ? proposal.context.ownerToken == ownerToken
              : proposal.identity.journalKey == outcome.key);
      final key = claimedByProposal ? _identity(proposal) : null;
      if (key != null) matched.add(key);
      try {
        await _apply(outcome, conversation, proposal);
      } on Object {
        // Retain the exact journal record for a later startup retry.
      }
    }
    await _resetUnclaimedExecuting(matched);
  }

  Conversation? _conversationForOwner(String? ownerToken, String key) {
    Conversation? match;
    for (final conversation in conversations.loadAll()) {
      final proposal = conversation.pendingWorkspaceProposal;
      if (proposal == null ||
          (ownerToken != null
              ? proposal.context.ownerToken != ownerToken
              : proposal.identity.journalKey != key)) {
        continue;
      }
      if (match != null) return null;
      match = conversation;
    }
    return match;
  }

  Future<void> _apply(
    WorkspaceStartupRecoveryOutcome outcome,
    Conversation? conversation,
    PendingWorkspaceProposal? proposal,
  ) async {
    final record = outcome.record;
    final operation = record?.operation ?? outcome.invalidHint?.operation;
    final ownerToken = record?.ownerToken ?? outcome.invalidHint?.ownerToken;
    final matches =
        proposal != null &&
        operation == proposal.identity &&
        ownerToken == proposal.context.ownerToken;
    final sameClaim =
        proposal != null &&
        proposal.identity.journalKey == outcome.key &&
        (operation != proposal.identity ||
            ownerToken != proposal.context.ownerToken);
    if (sameClaim && conversation != null) {
      if (record?.state == 'claimed' ||
          outcome.invalidHint?.provablyClaimOnly == true) {
        await _resetPending(conversation, proposal);
      } else {
        await _persistPayload(conversation, proposal, {
          'ok': false,
          'error_code': 'workspace_recovery_invalid',
          'workspace_recovery_key': outcome.key,
        });
      }
      await _acknowledgeInvalid(outcome, reason: 'proposal_mismatch');
      return;
    }
    if (outcome.kind == WorkspaceStartupRecoveryKind.invalid) {
      if (!matches || conversation == null) {
        if (_hasInvalidTerminal(outcome.key)) {
          await _acknowledgeInvalid(outcome);
        }
        return;
      }
      final hint = outcome.invalidHint;
      if (hint?.provablyClaimOnly == true) {
        await _resetPending(conversation, proposal);
      } else {
        await _persistPayload(conversation, proposal, {
          'ok': false,
          'error_code': 'workspace_recovery_invalid',
          'workspace_recovery_key': outcome.key,
        });
      }
      await _acknowledgeInvalid(outcome);
      return;
    }
    if (record == null) return;
    if (outcome.kind == WorkspaceStartupRecoveryKind.claimed) {
      if (matches && conversation != null) {
        if (proposal.status == WorkspaceProposalStatus.executing &&
            proposal.claimToken != record.claimToken) {
          await journal.quarantine(
            outcome.key,
            record.toJson(),
            'claim_mismatch',
          );
          await _resetPending(conversation, proposal);
          return;
        }
        if (proposal.status == WorkspaceProposalStatus.executing) {
          await _resetPending(conversation, proposal);
        }
        await journal.remove(outcome.key);
      } else if (!matches) {
        await journal.remove(outcome.key);
      }
      return;
    }
    if (outcome.kind == WorkspaceStartupRecoveryKind.blocked) return;
    if (outcome.kind == WorkspaceStartupRecoveryKind.terminal) {
      if (conversation != null && matches) {
        await _persistResult(conversation, proposal, record.result);
      }
      await _cleanup(outcome.key, record);
      return;
    }
    final result = outcome.kind == WorkspaceStartupRecoveryKind.committed
        ? WorkspaceMutationResult(
            outcome: WorkspaceMutationOutcome.committed,
            payload: record.operation.committedPayload,
            operationId: record.prepared!.operationId,
            token: record.prepared!.token,
          )
        : WorkspaceMutationResult(
            outcome: WorkspaceMutationOutcome.rolledBack,
            payload: const {'ok': false, 'outcome': 'rolledBack'},
            operationId: record.prepared!.operationId,
            token: record.prepared!.token,
          );
    if (conversation != null && matches) {
      await _persistResult(conversation, proposal, result);
    }
    await _cleanup(outcome.key, record);
    return;
  }

  Future<void> _acknowledgeInvalid(
    WorkspaceStartupRecoveryOutcome outcome, {
    String reason = 'invalid_schema',
  }) {
    final handle = outcome.invalidHandle;
    return _workspaceRecovery.acknowledgeInvalid(
      handle ??
          InvalidRecoveryHandle(
            key: outcome.key,
            record: outcome.activeRecord,
            hint: null,
          ),
      reason: reason,
    );
  }

  bool _hasInvalidTerminal(String key) {
    for (final conversation in conversations.loadAll()) {
      for (final message in conversation.messages) {
        if (message.role != ChatRole.tool) continue;
        try {
          final payload = jsonDecode(message.content);
          if (payload is Map &&
              payload['error_code'] == 'workspace_recovery_invalid' &&
              payload['workspace_recovery_key'] == key) {
            return true;
          }
        } on Object {
          // Non-JSON tool output cannot acknowledge a recovery record.
        }
      }
    }
    return false;
  }

  Future<void> _cleanup(String key, WorkspaceRecoveryRecord record) async {
    try {
      await _workspaceRecovery.cleanup(record);
      await journal.remove(key);
    } on Object {
      // Terminal cleanup is retried without suppressing conversation startup.
    }
  }

  Future<void> _resetUnclaimedExecuting(Set<String> matched) async {
    for (final conversation in conversations.loadAll()) {
      final proposal = conversation.pendingWorkspaceProposal;
      if (proposal?.status != WorkspaceProposalStatus.executing ||
          matched.contains(_identity(proposal!))) {
        continue;
      }
      await _resetPending(conversation, proposal);
    }
  }

  Future<void> _resetPending(
    Conversation conversation,
    PendingWorkspaceProposal proposal,
  ) => conversations.save(
    conversation.copyWith(
      updatedAt: DateTime.now(),
      pendingWorkspaceProposal: proposal.pending(),
    ),
  );

  Future<void> _persistResult(
    Conversation conversation,
    PendingWorkspaceProposal proposal,
    WorkspaceMutationResult result,
  ) => _persistPayload(conversation, proposal, {
    ...result.payload,
    'outcome': result.outcome.name,
  });

  Future<void> _persistPayload(
    Conversation conversation,
    PendingWorkspaceProposal proposal,
    Map<String, Object?> payload,
  ) async {
    final latest = conversations.loadById(conversation.id);
    if (latest?.pendingWorkspaceProposal?.hasSameIdentity(proposal) != true) {
      throw StateError('workspace_recovery_conversation_changed');
    }
    final now = DateTime.now();
    await conversations.save(
      latest!.copyWith(
        updatedAt: now,
        clearPendingRequest: true,
        clearPendingWorkspaceProposal: true,
        messages: [
          ...latest.messages.map(
            (message) =>
                message.status == ChatMessageStatus.pending ||
                    message.status == ChatMessageStatus.streaming
                ? message.copyWith(status: ChatMessageStatus.interrupted)
                : message,
          ),
          ChatMessage(
            id: '${now.microsecondsSinceEpoch}-workspace-recovery',
            role: ChatRole.tool,
            content: jsonEncode(payload),
            createdAt: now,
            toolCallId: proposal.toolCallId,
            toolCallIndex: proposal.toolCallIndex,
          ),
        ],
      ),
    );
  }

  String _identity(PendingWorkspaceProposal proposal) =>
      '${proposal.conversationId}\u0000${proposal.requestId}\u0000'
      '${proposal.toolCallId}\u0000${proposal.callOccurrence}';
}
