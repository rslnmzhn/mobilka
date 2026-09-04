import '../../../core/workspace/workspace_binding.dart';
import '../data/workspace_recovery_journal.dart';
import 'session_workspace_boundary.dart';
import 'workspace_recovery_record.dart';

enum WorkspaceStartupRecoveryKind {
  claimed,
  terminal,
  committed,
  rolledBack,
  blocked,
  invalid,
}

final class WorkspaceStartupRecoveryOutcome {
  const WorkspaceStartupRecoveryOutcome({
    required this.key,
    required this.kind,
    required this.activeRecord,
    this.record,
    this.invalidHandle,
  });

  final String key;
  final WorkspaceStartupRecoveryKind kind;
  final Object? activeRecord;
  final WorkspaceRecoveryRecord? record;
  final InvalidRecoveryHandle? invalidHandle;

  WorkspaceRecoveryInvalidHint? get invalidHint => invalidHandle?.hint;
}

final class InvalidRecoveryHandle {
  const InvalidRecoveryHandle({
    required this.key,
    required this.record,
    required this.hint,
  });

  final String key;
  final Object? record;
  final WorkspaceRecoveryInvalidHint? hint;
}

/// Conversation-agnostic journal inspection and native proof reconciliation.
final class WorkspaceStartupRecoveryService {
  WorkspaceStartupRecoveryService({
    required this.journal,
    required Future<WorkspaceBinding?> Function(
      WorkspaceBindingSnapshot snapshot,
    )
    restoreBinding,
    required SessionWorkspaceBoundary Function(
      WorkspaceBinding binding,
      String sessionKey,
    )
    boundaryFactory,
  }) : _restoreBinding = restoreBinding,
       _boundaryFactory = boundaryFactory;

  final WorkspaceRecoveryJournal journal;
  final Future<WorkspaceBinding?> Function(WorkspaceBindingSnapshot snapshot)
  _restoreBinding;
  final SessionWorkspaceBoundary Function(
    WorkspaceBinding binding,
    String sessionKey,
  )
  _boundaryFactory;

  Future<List<WorkspaceStartupRecoveryOutcome>> recover() async {
    final outcomes = <WorkspaceStartupRecoveryOutcome>[];
    for (final entry in journal.activeSnapshot().entries) {
      WorkspaceRecoveryRecord record;
      try {
        record = WorkspaceRecoveryRecord.decode(entry.value);
        final expectedKey = workspaceJournalKey(
          rootIdentity: record.rootIdentity,
          sessionKey: record.sessionKey,
          operationId: record.operation.operationId,
        );
        if (entry.key != expectedKey ||
            record.operation.rootIdentity != record.rootIdentity ||
            record.operation.sessionKey != record.sessionKey) {
          throw const FormatException('record_key_mismatch');
        }
      } on Object {
        final hint = WorkspaceRecoveryRecord.invalidHint(entry.value);
        outcomes.add(
          WorkspaceStartupRecoveryOutcome(
            key: entry.key,
            kind: WorkspaceStartupRecoveryKind.invalid,
            activeRecord: entry.value,
            invalidHandle: InvalidRecoveryHandle(
              key: entry.key,
              record: entry.value,
              hint: hint,
            ),
          ),
        );
        continue;
      }
      if (record.state == 'claimed') {
        outcomes.add(
          WorkspaceStartupRecoveryOutcome(
            key: entry.key,
            kind: WorkspaceStartupRecoveryKind.claimed,
            activeRecord: entry.value,
            record: record,
          ),
        );
        continue;
      }
      if (record.state == 'terminal') {
        outcomes.add(
          WorkspaceStartupRecoveryOutcome(
            key: entry.key,
            kind: WorkspaceStartupRecoveryKind.terminal,
            activeRecord: entry.value,
            record: record,
          ),
        );
        continue;
      }
      outcomes.add(await _reconcile(entry.key, entry.value, record));
    }
    return outcomes;
  }

  Future<WorkspaceStartupRecoveryOutcome> _reconcile(
    String key,
    Object? activeRecord,
    WorkspaceRecoveryRecord record,
  ) async {
    try {
      final binding = await _restoreBinding(record.bindingSnapshot);
      if (binding == null) {
        return _outcome(
          key,
          activeRecord,
          record,
          WorkspaceStartupRecoveryKind.blocked,
        );
      }
      final boundary = _boundaryFactory(binding, record.sessionKey);
      if (await boundary.rootIdentity() != record.rootIdentity) {
        return _outcome(
          key,
          activeRecord,
          record,
          WorkspaceStartupRecoveryKind.blocked,
        );
      }
      var state = await boundary.synchronized(
        () => boundary.reconcilePrepared(record.prepared!),
      );
      if (state == WorkspacePreparedState.notCommitted) {
        await boundary.synchronized(
          () => boundary.rollbackPrepared(record.prepared!),
        );
        state = await boundary.synchronized(
          () => boundary.reconcilePrepared(record.prepared!),
        );
      }
      return _outcome(key, activeRecord, record, switch (state) {
        WorkspacePreparedState.committed =>
          WorkspaceStartupRecoveryKind.committed,
        WorkspacePreparedState.rolledBack ||
        WorkspacePreparedState.notCommitted =>
          WorkspaceStartupRecoveryKind.rolledBack,
        WorkspacePreparedState.indeterminate =>
          WorkspaceStartupRecoveryKind.blocked,
      });
    } on Object {
      return _outcome(
        key,
        activeRecord,
        record,
        WorkspaceStartupRecoveryKind.blocked,
      );
    }
  }

  WorkspaceStartupRecoveryOutcome _outcome(
    String key,
    Object? activeRecord,
    WorkspaceRecoveryRecord record,
    WorkspaceStartupRecoveryKind kind,
  ) => WorkspaceStartupRecoveryOutcome(
    key: key,
    kind: kind,
    activeRecord: activeRecord,
    record: record,
  );

  Future<void> acknowledgeInvalid(
    InvalidRecoveryHandle handle, {
    String reason = 'invalid_schema',
  }) => journal.quarantine(
    handle.key,
    handle.record,
    reason,
    expectedActiveRecord: handle.record,
  );

  Future<void> cleanup(WorkspaceRecoveryRecord record) async {
    final binding = await _restoreBinding(record.bindingSnapshot);
    if (binding == null) {
      throw const WorkspaceBoundaryException('workspace_unavailable');
    }
    final boundary = _boundaryFactory(binding, record.sessionKey);
    if (await boundary.rootIdentity() != record.rootIdentity) {
      throw const WorkspaceBoundaryException('workspace_binding_changed');
    }
    await boundary.synchronized(
      () => boundary.cleanupPrepared(record.prepared!),
    );
  }
}
