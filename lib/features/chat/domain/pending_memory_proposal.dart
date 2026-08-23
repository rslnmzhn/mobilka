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
  }) : allowedTools = Set.unmodifiable(allowedTools);

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
  };

  factory PendingMemoryProposal.fromJson(Map<dynamic, dynamic> json) =>
      PendingMemoryProposal(
        toolCallId: json['toolCallId'].toString(),
        assistantMessageId: json['assistantMessageId'].toString(),
        callOccurrence: json['callOccurrence'] as int? ?? 0,
        selectedAgentId: json['selectedAgentId'].toString(),
        allowedTools: (json['allowedTools'] as List<dynamic>? ?? const [])
            .map((tool) => tool.toString())
            .toSet(),
        fileName: json['fileName'].toString(),
        proposedContent: json['proposedContent'].toString(),
        diff: json['diff'].toString(),
        confirmationToken: json['confirmationToken'].toString(),
        version: json['version'].toString(),
        createdAt: DateTime.parse(json['createdAt'].toString()),
      );
}
