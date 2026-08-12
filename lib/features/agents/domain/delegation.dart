enum DelegationStatus { completed, failed, cancelled }

class DelegationRequest {
  DelegationRequest({
    required this.parentConversationId,
    required this.parentRequestId,
    required this.subagentId,
    required this.task,
    this.context = '',
    this.depth = 1,
  }) {
    _requireBounded(parentConversationId, 'parentConversationId', 200);
    _requireBounded(parentRequestId, 'parentRequestId', 200);
    _requireBounded(subagentId, 'subagentId', 64);
    _requireBounded(task, 'task', maxTaskCharacters);
    if (context.length > maxContextCharacters) {
      throw ArgumentError.value(context.length, 'context', 'is too long');
    }
    if (depth < 1 || depth > maxDepth) {
      throw ArgumentError.value(
        depth,
        'depth',
        'must be between 1 and $maxDepth',
      );
    }
  }

  static const maxDepth = 1;
  static const maxTaskCharacters = 16000;
  static const maxContextCharacters = 32000;

  final String parentConversationId;
  final String parentRequestId;
  final String subagentId;
  final String task;
  final String context;
  final int depth;

  static void _requireBounded(String value, String name, int maximum) {
    if (value.trim().isEmpty || value.length > maximum) {
      throw ArgumentError.value(value, name, 'must be non-empty and bounded');
    }
  }
}

class DelegationResult {
  DelegationResult({
    required this.parentConversationId,
    required this.parentRequestId,
    required this.subagentId,
    required this.status,
    required this.content,
    this.error,
  }) {
    DelegationRequest._requireBounded(
      parentConversationId,
      'parentConversationId',
      200,
    );
    DelegationRequest._requireBounded(parentRequestId, 'parentRequestId', 200);
    DelegationRequest._requireBounded(subagentId, 'subagentId', 64);
    if (content.length > maxContentCharacters) {
      throw ArgumentError.value(content.length, 'content', 'is too long');
    }
    if (error != null && error!.length > maxErrorCharacters) {
      throw ArgumentError.value(error!.length, 'error', 'is too long');
    }
  }

  static const maxContentCharacters = 64000;
  static const maxErrorCharacters = 4000;

  final String parentConversationId;
  final String parentRequestId;
  final String subagentId;
  final DelegationStatus status;
  final String content;
  final String? error;
}
