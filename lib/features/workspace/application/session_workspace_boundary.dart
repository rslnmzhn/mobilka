import '../domain/session_workspace_path.dart';
import '../domain/workspace_models.dart';

abstract interface class SessionWorkspaceBoundary {
  Future<String> rootIdentity();

  Future<T> synchronized<T>(Future<T> Function() action);

  Future<List<WorkspaceEntry>> list(
    SessionWorkspacePath path, {
    required bool recursive,
  });

  Future<WorkspaceReadResult> read(
    SessionWorkspacePath path, {
    required int offset,
    required int maxBytes,
  });

  Future<WorkspaceEntry?> metadata(SessionWorkspacePath path);

  /// Creates durable hidden staging without changing the logical namespace.
  Future<PreparedWorkspaceMutation> prepareMutation(
    String operationId,
    WorkspaceMutationPlan plan,
  );

  Future<void> commitPrepared(PreparedWorkspaceMutation prepared);

  Future<WorkspacePreparedState> reconcilePrepared(
    PreparedWorkspaceMutation prepared,
  );

  Future<void> rollbackPrepared(PreparedWorkspaceMutation prepared);

  Future<void> cleanupPrepared(PreparedWorkspaceMutation prepared);
}

enum WorkspacePreparedState {
  committed,
  notCommitted,
  rolledBack,
  indeterminate,
}

final class WorkspaceMutationPlan {
  const WorkspaceMutationPlan({
    required this.operation,
    required this.path,
    required this.destination,
    required this.bytes,
    required this.expectedIdentity,
    required this.expectedHash,
    required this.expectMissing,
  });

  final String operation;
  final SessionWorkspacePath path;
  final SessionWorkspacePath? destination;
  final List<int>? bytes;
  final String? expectedIdentity;
  final String? expectedHash;
  final bool expectMissing;

  Map<String, Object?> toJson() => {
    'operation': operation,
    'path': path.value,
    'destination': destination?.value,
    'bytes': bytes,
    'expectedIdentity': expectedIdentity,
    'expectedHash': expectedHash,
    'expectMissing': expectMissing,
  };
}

final class PreparedWorkspaceMutation {
  const PreparedWorkspaceMutation({
    required this.operationId,
    required this.token,
  });

  final String operationId;
  final String token;

  factory PreparedWorkspaceMutation.fromJson(Map<Object?, Object?> json) {
    const keys = {'operationId', 'token'};
    final operationId = json['operationId'];
    final token = json['token'];
    if (json.length != keys.length ||
        !json.keys.toSet().containsAll(keys) ||
        operationId is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(operationId) ||
        token is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      throw const WorkspaceBoundaryException('invalid_prepared_receipt');
    }
    return PreparedWorkspaceMutation(operationId: operationId, token: token);
  }

  Map<String, Object?> toJson() => {'operationId': operationId, 'token': token};
}

class WorkspaceBoundaryException implements Exception {
  const WorkspaceBoundaryException(this.code);
  final String code;
  @override
  String toString() => code;
}
