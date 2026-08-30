class PendingMemoryProposal {
  PendingMemoryProposal({
    required this.toolCallId,
    required this.assistantMessageId,
    this.callOccurrence = 0,
    required this.selectedAgentId,
    required Set<String> allowedTools,
    required this.fileName,
    required this.proposedContent,
    required this.diff,
    required this.confirmationToken,
    required this.version,
    required this.createdAt,
    String? requiredToolPermission,
  }) : allowedTools = Set.unmodifiable(allowedTools),
       requiredToolPermission = requiredToolPermission ?? 'update_memory_file';

  final String toolCallId;
  final String assistantMessageId;
  final int callOccurrence;
  final String selectedAgentId;
  final Set<String> allowedTools;
  final String fileName;
  final String proposedContent;
  final String diff;
  final String confirmationToken;
  final String version;
  final DateTime createdAt;
  final String requiredToolPermission;

  /// Security-bound equality used while confirming a persisted proposal.
  bool hasSameIdentity(PendingMemoryProposal other) =>
      toolCallId == other.toolCallId &&
      assistantMessageId == other.assistantMessageId &&
      callOccurrence == other.callOccurrence &&
      selectedAgentId == other.selectedAgentId &&
      allowedTools.length == other.allowedTools.length &&
      allowedTools.containsAll(other.allowedTools) &&
      fileName == other.fileName &&
      proposedContent == other.proposedContent &&
      diff == other.diff &&
      confirmationToken == other.confirmationToken &&
      version == other.version &&
      createdAt == other.createdAt &&
      requiredToolPermission == other.requiredToolPermission;

  PendingMemoryProposal withRequiredToolPermission(String permission) =>
      PendingMemoryProposal(
        toolCallId: toolCallId,
        assistantMessageId: assistantMessageId,
        callOccurrence: callOccurrence,
        selectedAgentId: selectedAgentId,
        allowedTools: allowedTools,
        fileName: fileName,
        proposedContent: proposedContent,
        diff: diff,
        confirmationToken: confirmationToken,
        version: version,
        createdAt: createdAt,
        requiredToolPermission: permission,
      );

  Map<String, dynamic> toJson() => {
    'toolCallId': toolCallId,
    'assistantMessageId': assistantMessageId,
    'callOccurrence': callOccurrence,
    'selectedAgentId': selectedAgentId,
    'allowedTools': allowedTools.toList(growable: false),
    'fileName': fileName,
    'proposedContent': proposedContent,
    'diff': diff,
    'confirmationToken': confirmationToken,
    'version': version,
    'createdAt': createdAt.toIso8601String(),
    'requiredToolPermission': requiredToolPermission,
  };

  factory PendingMemoryProposal.fromJson(Map<dynamic, dynamic> json) {
    final fileName = json['fileName'].toString();
    final explicit = json['requiredToolPermission'] as String?;
    final operation = json['operation'] as String?;
    final permission = explicit ?? operation ?? _legacyPermission(fileName);
    _validatePermissionBinding(permission, fileName);
    return PendingMemoryProposal(
      toolCallId: json['toolCallId'].toString(),
      assistantMessageId: json['assistantMessageId'].toString(),
      callOccurrence: json['callOccurrence'] as int? ?? 0,
      selectedAgentId: json['selectedAgentId'].toString(),
      allowedTools: (json['allowedTools'] as List<dynamic>? ?? const [])
          .map((tool) => tool.toString())
          .toSet(),
      fileName: fileName,
      proposedContent: json['proposedContent'].toString(),
      diff: json['diff'].toString(),
      confirmationToken: json['confirmationToken'].toString(),
      version: json['version'].toString(),
      createdAt: DateTime.parse(json['createdAt'].toString()),
      requiredToolPermission: permission,
    );
  }
}

String _legacyPermission(String fileName) {
  if (fileName == 'user.md') return 'update_memory_file';
  throw const FormatException(
    'Legacy protected memory proposal cannot be safely authorized',
  );
}

void validateMemoryProposalPermissionBinding(
  String permission,
  String fileName,
) => _validatePermissionBinding(permission, fileName);

void _validatePermissionBinding(String permission, String fileName) {
  final valid = switch (permission) {
    'update_memory_file' => fileName == 'user.md',
    'save_persona' || 'delete_persona' => RegExp(
      r'^personas/[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?\.md$',
    ).hasMatch(fileName),
    _ => false,
  };
  if (!valid) {
    throw const FormatException(
      'Memory proposal permission does not match target',
    );
  }
}
