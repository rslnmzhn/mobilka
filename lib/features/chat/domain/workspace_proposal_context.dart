import 'dart:convert';

final class WorkspaceProposalContext {
  WorkspaceProposalContext({
    required this.conversationId,
    required this.requestId,
    required this.assistantMessageId,
    required this.toolCallId,
    required this.callOccurrence,
    required this.toolCallIndex,
    required this.selectedAgentId,
    required Set<String> allowedTools,
    required this.ownerToken,
  }) : allowedTools = Set.unmodifiable(allowedTools);

  final String conversationId;
  final String requestId;
  final String assistantMessageId;
  final String toolCallId;
  final int callOccurrence;
  final int toolCallIndex;
  final String selectedAgentId;
  final Set<String> allowedTools;
  final String ownerToken;

  Map<String, Object?> toJson() => {
    'conversationId': conversationId,
    'requestId': requestId,
    'assistantMessageId': assistantMessageId,
    'toolCallId': toolCallId,
    'callOccurrence': callOccurrence,
    'toolCallIndex': toolCallIndex,
    'selectedAgentId': selectedAgentId,
    'allowedTools': allowedTools.toList()..sort(),
    'ownerToken': ownerToken,
  };

  factory WorkspaceProposalContext.fromJson(Map<Object?, Object?> source) {
    final json = Map<String, Object?>.from(source);
    if (json.length != 9 ||
        json['conversationId'] is! String ||
        json['requestId'] is! String ||
        json['assistantMessageId'] is! String ||
        json['toolCallId'] is! String ||
        json['callOccurrence'] is! int ||
        json['toolCallIndex'] is! int ||
        json['selectedAgentId'] is! String ||
        json['allowedTools'] is! List ||
        (json['allowedTools']! as List).any((value) => value is! String) ||
        json['ownerToken'] is! String) {
      throw const FormatException('workspace_proposal_context');
    }
    return WorkspaceProposalContext(
      conversationId: json['conversationId']! as String,
      requestId: json['requestId']! as String,
      assistantMessageId: json['assistantMessageId']! as String,
      toolCallId: json['toolCallId']! as String,
      callOccurrence: json['callOccurrence']! as int,
      toolCallIndex: json['toolCallIndex']! as int,
      selectedAgentId: json['selectedAgentId']! as String,
      allowedTools: (json['allowedTools']! as List).cast<String>().toSet(),
      ownerToken: json['ownerToken']! as String,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WorkspaceProposalContext &&
      jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}
