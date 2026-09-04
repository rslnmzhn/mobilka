import 'dart:convert';

import 'package:mobilka/features/workspace/application/session_workspace_boundary.dart';
import 'package:mobilka/features/workspace/domain/session_workspace_path.dart';
import 'package:mobilka/features/workspace/domain/workspace_models.dart';
import 'package:synchronized/synchronized.dart';

final class MemoryWorkspaceBoundaryFake implements SessionWorkspaceBoundary {
  final files = <String, List<int>>{};
  final directories = <String>{};
  final _lock = Lock();
  var lockDepth = 0;
  var maxLockDepth = 0;
  var failAfterWrite = false;
  var failRollback = false;
  var indeterminateReconcile = false;
  var authorizationChecked = false;
  void Function()? onPrepare;
  final prepared = <String, PreparedWorkspaceStateFake>{};

  @override
  Future<String> rootIdentity() async => 'root';

  void seed(String path, String content) => files[path] = utf8.encode(content);

  WorkspaceEntry? entry(String path) {
    final bytes = files[path];
    if (bytes != null) {
      return WorkspaceEntry(
        path: path,
        type: WorkspaceEntryType.file,
        size: bytes.length,
        identity: 'file:$path',
        sha256: workspaceHash(bytes),
      );
    }
    if (directories.contains(path)) {
      return WorkspaceEntry(
        path: path,
        type: WorkspaceEntryType.directory,
        size: 0,
        identity: 'dir:$path',
      );
    }
    return null;
  }

  @override
  Future<T> synchronized<T>(Future<T> Function() action) =>
      _lock.synchronized(() async {
        lockDepth++;
        maxLockDepth = lockDepth > maxLockDepth ? lockDepth : maxLockDepth;
        try {
          return await action();
        } finally {
          lockDepth--;
        }
      });

  @override
  Future<List<WorkspaceEntry>> list(
    SessionWorkspacePath path, {
    required bool recursive,
  }) async => [
    for (final path in files.keys) entry(path)!,
    for (final path in directories) entry(path)!,
  ];

  @override
  Future<WorkspaceEntry?> metadata(SessionWorkspacePath path) async =>
      entry(path.value);

  @override
  Future<WorkspaceReadResult> read(
    SessionWorkspacePath path, {
    required int offset,
    required int maxBytes,
  }) async {
    final bytes = files[path.value]!;
    final end = (offset + maxBytes).clamp(offset, bytes.length);
    return WorkspaceReadResult(
      content: utf8.decode(bytes.sublist(offset, end)),
      size: bytes.length,
      sha256: workspaceHash(bytes),
      nextOffset: end,
      truncated: end < bytes.length,
      identity: 'file:${path.value}',
    );
  }

  @override
  Future<PreparedWorkspaceMutation> prepareMutation(
    String operationId,
    WorkspaceMutationPlan plan,
  ) async {
    onPrepare?.call();
    prepared[operationId] = PreparedWorkspaceStateFake(plan);
    return PreparedWorkspaceMutation(operationId: operationId, token: 'b' * 43);
  }

  PreparedWorkspaceStateFake _state(PreparedWorkspaceMutation receipt) =>
      prepared[receipt.operationId]!;

  @override
  Future<void> commitPrepared(PreparedWorkspaceMutation receipt) async {
    final state = _state(receipt);
    final plan = state.plan;
    final current = entry(plan.path.value);
    if (plan.expectMissing
        ? current != null
        : current?.identity != plan.expectedIdentity ||
              current?.sha256 != plan.expectedHash) {
      throw const WorkspaceBoundaryException('stale_target');
    }
    state.before = files[plan.path.value] == null
        ? null
        : List<int>.of(files[plan.path.value]!);
    switch (plan.operation) {
      case 'write_file':
      case 'apply_patch':
        files[plan.path.value] = List.of(plan.bytes!);
      case 'move_file':
        files[plan.destination!.value] = files.remove(plan.path.value)!;
      case 'delete_file':
        files.remove(plan.path.value);
      case 'make_directory':
        directories.add(plan.path.value);
    }
    state.committed = true;
    if (failAfterWrite) {
      failAfterWrite = false;
      throw const WorkspaceBoundaryException('crash_after_write');
    }
  }

  @override
  Future<WorkspacePreparedState> reconcilePrepared(
    PreparedWorkspaceMutation receipt,
  ) async {
    if (indeterminateReconcile) return WorkspacePreparedState.indeterminate;
    final state = _state(receipt);
    if (state.rolledBack) return WorkspacePreparedState.rolledBack;
    return state.committed
        ? WorkspacePreparedState.committed
        : WorkspacePreparedState.notCommitted;
  }

  @override
  Future<void> rollbackPrepared(PreparedWorkspaceMutation receipt) async {
    if (failRollback) throw StateError('rollback_failed');
    _state(receipt).rolledBack = true;
  }

  @override
  Future<void> cleanupPrepared(PreparedWorkspaceMutation receipt) async {
    prepared.remove(receipt.operationId);
  }
}

final class PreparedWorkspaceStateFake {
  PreparedWorkspaceStateFake(this.plan);
  final WorkspaceMutationPlan plan;
  List<int>? before;
  bool committed = false;
  bool rolledBack = false;
}
