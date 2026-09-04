import '../../../core/workspace/workspace_binding.dart';
import '../data/workspace_recovery_journal.dart';
import '../domain/session_workspace_path.dart';
import '../domain/workspace_models.dart';
import '../domain/workspace_mutation_result.dart';
import '../domain/workspace_operation_identity.dart';
import 'session_workspace_boundary.dart';
import 'workspace_recovery_record.dart';
import 'workspace_mutation_validator.dart';

export '../domain/workspace_mutation_result.dart';
export 'workspace_recovery_record.dart' show WorkspaceRecoveryPendingException;

/// Serializes mutations around boundary-issued, durable operation proofs.
final class WorkspaceMutationCoordinator {
  WorkspaceMutationCoordinator({
    required this.rootIdentity,
    required this.sessionKey,
    required SessionWorkspaceBoundary boundary,
    required WorkspaceRecoveryJournal journal,
  }) : _boundary = boundary,
       _journal = journal {
    SessionWorkspacePath.parse(sessionKey);
  }

  final String rootIdentity;
  final String sessionKey;
  final SessionWorkspaceBoundary _boundary;
  final WorkspaceRecoveryJournal _journal;

  String get _prefix => workspaceJournalNamespace(rootIdentity, sessionKey);

  Future<T> synchronized<T>(
    Future<T> Function(SessionWorkspaceBoundary boundary) action,
  ) => _boundary.synchronized(() async {
    await _recoverLocked();
    return action(_boundary);
  });

  Future<WorkspaceMutationResult> commit({
    required WorkspaceOperationIdentity identity,
    required String ownerToken,
    required String? proposedContent,
    required DateTime expiresAt,
    required String claimToken,
    required Future<void> Function() revalidateAuthorization,
  }) => _boundary.synchronized(() async {
    await _recoverLocked(allowClaimKey: _journalKey(identity));
    return _commitLocked(
      _boundary,
      identity,
      ownerToken,
      proposedContent,
      expiresAt,
      claimToken,
      revalidateAuthorization,
    );
  });

  Future<String> beginClaim(
    WorkspaceOperationIdentity identity,
    WorkspaceBindingSnapshot bindingSnapshot,
    String ownerToken,
  ) async {
    if (identity.rootIdentity != rootIdentity) {
      throw StateError('workspace_proposal_not_pending');
    }
    final token = newWorkspaceRecoveryToken(32);
    final key = _journalKey(identity);
    await _boundary.synchronized(() async {
      await _recoverLocked(allowClaimKey: key);
      if (_journal.snapshot().containsKey(key)) {
        throw StateError('workspace_claim_exists');
      }
      await _journal.put(
        key,
        WorkspaceRecoveryRecord.claimed(
          identity,
          bindingSnapshot,
          token,
          ownerToken,
        ).toJson(),
      );
    });
    return token;
  }

  Future<void> abandonClaim(
    WorkspaceOperationIdentity identity,
    String token,
    String ownerToken,
  ) => _boundary.synchronized(() async {
    final key = _journalKey(identity);
    final raw = _journal.snapshot()[key];
    if (raw == null) return;
    final record = WorkspaceRecoveryRecord.decode(raw);
    if (record.state != 'claimed' ||
        record.claimToken != token ||
        record.ownerToken != ownerToken) {
      throw StateError('workspace_claim_changed');
    }
    await _journal.remove(key);
  });

  Future<void> recover() => _boundary.synchronized(_recoverLocked);

  Future<void> recoverLocked(SessionWorkspaceBoundary boundary) =>
      _recoverLocked(ownedBoundary: boundary);

  String _journalKey(WorkspaceOperationIdentity proposal) =>
      workspaceJournalKey(
        rootIdentity: rootIdentity,
        sessionKey: sessionKey,
        operationId: proposal.operationId,
      );

  bool _ownsJournalKey(String key) {
    if (!key.startsWith(_prefix)) return false;
    final suffix = key.substring(_prefix.length);
    return RegExp(r'^[a-f0-9]{64}$').hasMatch(suffix);
  }

  Future<WorkspaceMutationResult?> reconcileProposal(
    WorkspaceOperationIdentity proposal,
    String? claimToken,
    String ownerToken,
  ) => _boundary.synchronized(() async {
    final key = _journalKey(proposal);
    final entry = _journal
        .snapshot()
        .entries
        .where((candidate) => candidate.key == key)
        .firstOrNull;
    if (entry == null) return null;
    final record = WorkspaceRecoveryRecord.decode(entry.value);
    if (record.rootIdentity != rootIdentity ||
        record.sessionKey != sessionKey) {
      throw const FormatException('record_binding');
    }
    record.verifyOperation(proposal, claimToken, ownerToken);
    if (record.state == 'terminal') return record.result;
    if (record.state == 'claimed') return null;
    final state = await _boundary.reconcilePrepared(record.prepared!);
    if (state == WorkspacePreparedState.indeterminate) {
      return null;
    }
    if (state == WorkspacePreparedState.notCommitted) {
      await _boundary.rollbackPrepared(record.prepared!);
      final rolledBack = await _boundary.reconcilePrepared(record.prepared!);
      if (rolledBack != WorkspacePreparedState.rolledBack &&
          rolledBack != WorkspacePreparedState.notCommitted) {
        return null;
      }
    }
    final result = state == WorkspacePreparedState.committed
        ? _committedResult(record.prepared!, proposal)
        : _rolledBackResult(record.prepared!);
    await _persistTerminal(entry.key, record, result);
    return result;
  });

  Future<void> acknowledgeOutcome(String operationId, String token) =>
      _boundary.synchronized(() async {
        final matches = <MapEntry<String, Object?>>[];
        for (final entry in _journal.snapshot().entries) {
          if (!_ownsJournalKey(entry.key)) continue;
          final record = WorkspaceRecoveryRecord.decode(entry.value);
          if (record.prepared?.operationId == operationId &&
              record.prepared?.token == token) {
            matches.add(entry);
          }
        }
        if (matches.length != 1) {
          throw StateError('workspace_outcome_not_found');
        }
        final entry = matches.single;
        final record = WorkspaceRecoveryRecord.decode(entry.value);
        if (record.state != 'terminal') {
          throw StateError('workspace_outcome_not_terminal');
        }
        await _boundary.cleanupPrepared(record.prepared!);
        await _journal.remove(entry.key);
      });

  Future<void> _recoverLocked({
    SessionWorkspaceBoundary? ownedBoundary,
    String? allowClaimKey,
  }) async {
    final boundary = ownedBoundary ?? _boundary;
    var blocked = false;
    for (final entry in _journal.activeSnapshot().entries) {
      if (!_ownsJournalKey(entry.key)) continue;
      WorkspaceRecoveryRecord record;
      try {
        record = WorkspaceRecoveryRecord.decode(entry.value);
        if (record.rootIdentity != rootIdentity ||
            record.sessionKey != sessionKey) {
          throw const FormatException('record_binding');
        }
      } on Object {
        await _journal.quarantine(entry.key, entry.value, 'invalid_schema');
        blocked = true;
        continue;
      }
      try {
        if (record.state == 'claimed') {
          if (entry.key != allowClaimKey) blocked = true;
          continue;
        }
        if (record.state == 'terminal') {
          blocked = true;
          continue;
        }
        final state = await boundary.reconcilePrepared(record.prepared!);
        if (state == WorkspacePreparedState.indeterminate) {
          blocked = true;
          continue;
        }
        if (state == WorkspacePreparedState.notCommitted) {
          await boundary.rollbackPrepared(record.prepared!);
          final rolledBack = await boundary.reconcilePrepared(record.prepared!);
          if (rolledBack != WorkspacePreparedState.rolledBack &&
              rolledBack != WorkspacePreparedState.notCommitted) {
            blocked = true;
            continue;
          }
        }
        // The conversation is the acknowledgement authority. Generic reads
        // must not discard a terminal proof before startup recovery stores it.
        blocked = true;
      } on Object {
        blocked = true;
      }
    }
    if (blocked) {
      throw const WorkspaceRecoveryPendingException(
        'workspace_recovery_pending',
      );
    }
  }

  Future<WorkspaceMutationResult> _commitLocked(
    SessionWorkspaceBoundary boundary,
    WorkspaceOperationIdentity proposal,
    String ownerToken,
    String? proposedContent,
    DateTime expiresAt,
    String claimToken,
    Future<void> Function() revalidateAuthorization,
  ) async {
    WorkspaceMutationValidator.verifyProposal(
      proposal: proposal,
      rootIdentity: rootIdentity,
      sessionKey: sessionKey,
      expiresAt: expiresAt,
      claimToken: claimToken,
    );
    final key = _journalKey(proposal);
    final rawClaim = _journal.snapshot()[key];
    if (rawClaim == null) throw StateError('workspace_claim_missing');
    final claimed = WorkspaceRecoveryRecord.decode(rawClaim);
    if (claimed.state != 'claimed' ||
        claimed.rootIdentity != rootIdentity ||
        claimed.sessionKey != sessionKey) {
      throw StateError('workspace_claim_missing');
    }
    claimed.verifyOperation(proposal, claimToken, ownerToken);
    final path = SessionWorkspacePath.parse(proposal.path);
    final destination = proposal.destination == null
        ? null
        : SessionWorkspacePath.parse(proposal.destination!);
    final source = await boundary.metadata(path);
    final target = destination == null
        ? source
        : await boundary.metadata(destination);
    WorkspaceMutationValidator.verifyEntry(
      source,
      proposal.sourceIdentity,
      proposal.sourceHash,
      proposal.sourceType,
      missing: proposal.sourceIdentity == null,
    );
    if (destination != null) {
      WorkspaceMutationValidator.verifyEntry(
        target,
        proposal.targetIdentity,
        proposal.targetHash,
        proposal.targetType,
        missing: proposal.targetMissing,
      );
      if (!proposal.targetMissing) {
        throw StateError('workspace_destination_exists');
      }
    }
    final entries = await boundary.list(
      SessionWorkspacePath.parse('', allowRoot: true),
      recursive: true,
    );
    WorkspaceMutationValidator.verifyQuota(
      entries,
      proposal,
      source,
      proposedContent,
    );
    final bytes = proposedContent == null
        ? null
        : encodeWorkspaceText(proposedContent);
    final operationId = newWorkspaceRecoveryToken(24);
    await revalidateAuthorization();
    final prepared = await boundary.prepareMutation(
      operationId,
      WorkspaceMutationPlan(
        operation: proposal.operation,
        path: path,
        destination: destination,
        bytes: bytes,
        expectedIdentity: source?.identity,
        expectedHash: source?.sha256,
        expectMissing: source == null,
      ),
    );
    try {
      _validateReceipt(prepared, operationId, proposal);
    } on Object {
      try {
        await boundary.rollbackPrepared(prepared);
        await boundary.cleanupPrepared(prepared);
      } on Object {
        // The logical namespace is unchanged; an invalid hidden receipt cannot
        // be journaled safely and is left inaccessible for boundary GC.
      }
      rethrow;
    }
    final record = claimed.preparedWith(prepared);
    try {
      await _journal.put(key, record.toJson());
    } on Object {
      await boundary.rollbackPrepared(prepared);
      await boundary.cleanupPrepared(prepared);
      rethrow;
    }
    try {
      await boundary.commitPrepared(prepared);
    } on Object {
      return _resolveFailedCommit(boundary, key, record);
    }
    final state = await boundary.reconcilePrepared(prepared);
    if (state != WorkspacePreparedState.committed) {
      return _resolveFailedCommit(boundary, key, record);
    }
    final result = _committedResult(prepared, proposal);
    await _persistTerminal(key, record, result);
    return result;
  }

  Future<WorkspaceMutationResult> _resolveFailedCommit(
    SessionWorkspaceBoundary boundary,
    String key,
    WorkspaceRecoveryRecord record,
  ) async {
    try {
      final state = await boundary.reconcilePrepared(record.prepared!);
      if (state == WorkspacePreparedState.committed) {
        final result = WorkspaceMutationResult(
          outcome: WorkspaceMutationOutcome.committed,
          operationId: record.prepared!.operationId,
          token: record.prepared!.token,
          payload: record.operation.committedPayload,
        );
        await _persistTerminal(key, record, result);
        return result;
      }
      if (state == WorkspacePreparedState.notCommitted) {
        await boundary.rollbackPrepared(record.prepared!);
        final after = await boundary.reconcilePrepared(record.prepared!);
        if (after == WorkspacePreparedState.rolledBack ||
            after == WorkspacePreparedState.notCommitted) {
          final result = _rolledBackResult(record.prepared!);
          await _persistTerminal(key, record, result);
          return result;
        }
      }
    } on Object {
      // Retain the exact receipt. Recovery will retry without hash inference.
    }
    return WorkspaceMutationResult(
      outcome: WorkspaceMutationOutcome.indeterminate,
      operationId: record.prepared!.operationId,
      token: record.prepared!.token,
      payload: const {
        'ok': false,
        'error_code': 'workspace_recovery_indeterminate',
        'outcome': 'indeterminate',
        'action': 'Recovery is blocked pending exact operation proof.',
      },
    );
  }

  Future<void> _persistTerminal(
    String key,
    WorkspaceRecoveryRecord record,
    WorkspaceMutationResult result,
  ) async {
    await _journal.put(key, record.terminal(result).toJson());
  }

  WorkspaceMutationResult _committedResult(
    PreparedWorkspaceMutation prepared,
    WorkspaceOperationIdentity proposal,
  ) => WorkspaceMutationResult(
    outcome: WorkspaceMutationOutcome.committed,
    operationId: prepared.operationId,
    token: prepared.token,
    payload: {
      'ok': true,
      'operation': proposal.operation,
      'path': proposal.path,
      if (proposal.destination != null) 'destination': proposal.destination,
      if (proposal.proposedContentHash != null)
        'sha256': proposal.proposedContentHash,
    },
  );

  WorkspaceMutationResult _rolledBackResult(
    PreparedWorkspaceMutation prepared,
  ) => WorkspaceMutationResult(
    outcome: WorkspaceMutationOutcome.rolledBack,
    operationId: prepared.operationId,
    token: prepared.token,
    payload: const {'ok': false, 'outcome': 'rolledBack'},
  );

  void _validateReceipt(
    PreparedWorkspaceMutation receipt,
    String operationId,
    WorkspaceOperationIdentity proposal,
  ) {
    if (receipt.operationId != operationId) {
      throw const WorkspaceBoundaryException('invalid_prepared_receipt');
    }
  }
}
