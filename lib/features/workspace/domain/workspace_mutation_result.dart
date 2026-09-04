enum WorkspaceMutationOutcome { committed, rolledBack, indeterminate }

final class WorkspaceMutationResult {
  const WorkspaceMutationResult({
    required this.outcome,
    required this.payload,
    required this.operationId,
    required this.token,
  });

  final WorkspaceMutationOutcome outcome;
  final Map<String, Object?> payload;
  final String operationId;
  final String token;
}
