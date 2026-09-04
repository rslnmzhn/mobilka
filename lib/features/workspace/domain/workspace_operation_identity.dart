import 'dart:convert';

/// Conversation-neutral identity and compare-and-swap proof for one proposed
/// session-workspace operation.
final class WorkspaceOperationIdentity {
  const WorkspaceOperationIdentity({
    required this.operationId,
    required this.sessionKey,
    required this.rootIdentity,
    required this.operation,
    required this.path,
    required this.destination,
    required this.proposedContentHash,
    required this.sourceIdentity,
    required this.sourceHash,
    required this.sourceType,
    required this.targetIdentity,
    required this.targetHash,
    required this.targetType,
    required this.targetMissing,
  });

  final String operationId;
  final String sessionKey;
  final String rootIdentity;
  final String operation;
  final String path;
  final String? destination;
  final String? proposedContentHash;
  final String? sourceIdentity;
  final String? sourceHash;
  final String? sourceType;
  final String? targetIdentity;
  final String? targetHash;
  final String? targetType;
  final bool targetMissing;

  Map<String, Object?> get committedPayload => {
    'ok': true,
    'operation': operation,
    'path': path,
    if (destination != null) 'destination': destination,
    if (proposedContentHash != null) 'sha256': proposedContentHash,
  };

  String get journalKey =>
      '${base64Url.encode(utf8.encode(rootIdentity))}.'
      '${base64Url.encode(utf8.encode(sessionKey))}.$operationId';

  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'sessionKey': sessionKey,
    'rootIdentity': rootIdentity,
    'operation': operation,
    'path': path,
    'destination': destination,
    'proposedContentHash': proposedContentHash,
    'sourceIdentity': sourceIdentity,
    'sourceHash': sourceHash,
    'sourceType': sourceType,
    'targetIdentity': targetIdentity,
    'targetHash': targetHash,
    'targetType': targetType,
    'targetMissing': targetMissing,
  };

  factory WorkspaceOperationIdentity.fromJson(Map<Object?, Object?> source) {
    final json = Map<String, Object?>.from(source);
    const keys = {
      'operationId',
      'sessionKey',
      'rootIdentity',
      'operation',
      'path',
      'destination',
      'proposedContentHash',
      'sourceIdentity',
      'sourceHash',
      'sourceType',
      'targetIdentity',
      'targetHash',
      'targetType',
      'targetMissing',
    };
    String? optional(String key) {
      final value = json[key];
      if (value != null && value is! String) {
        throw const FormatException('operation_identity');
      }
      return value as String?;
    }

    if (json.length != keys.length ||
        !json.keys.toSet().containsAll(keys) ||
        json['operationId'] is! String ||
        json['sessionKey'] is! String ||
        json['rootIdentity'] is! String ||
        json['operation'] is! String ||
        json['path'] is! String ||
        json['targetMissing'] is! bool) {
      throw const FormatException('operation_identity');
    }
    final identity = WorkspaceOperationIdentity(
      operationId: json['operationId']! as String,
      sessionKey: json['sessionKey']! as String,
      rootIdentity: json['rootIdentity']! as String,
      operation: json['operation']! as String,
      path: json['path']! as String,
      destination: optional('destination'),
      proposedContentHash: optional('proposedContentHash'),
      sourceIdentity: optional('sourceIdentity'),
      sourceHash: optional('sourceHash'),
      sourceType: optional('sourceType'),
      targetIdentity: optional('targetIdentity'),
      targetHash: optional('targetHash'),
      targetType: optional('targetType'),
      targetMissing: json['targetMissing']! as bool,
    );
    if (identity.operationId.isEmpty ||
        identity.sessionKey.isEmpty ||
        identity.rootIdentity.isEmpty ||
        identity.operation.isEmpty ||
        identity.path.isEmpty) {
      throw const FormatException('operation_identity');
    }
    return identity;
  }

  @override
  bool operator ==(Object other) =>
      other is WorkspaceOperationIdentity &&
      jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}
