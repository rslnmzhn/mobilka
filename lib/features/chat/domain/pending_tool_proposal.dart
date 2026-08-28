import 'chat_message.dart';
import 'chat_tool.dart';

enum PendingToolProposalState {
  pending,
  executing,
  completed,
  rejected,
  failed,
  indeterminate,
}

class PendingToolProposal {
  PendingToolProposal({
    required this.conversationId,
    required this.requestId,
    required this.assistantMessageId,
    required this.callOccurrence,
    required this.call,
    required this.selectedAgentId,
    required Set<String> allowedTools,
    required this.effect,
    required this.sourceTainted,
    required this.permissionSnapshot,
    this.state = PendingToolProposalState.pending,
    required this.createdAt,
  }) : allowedTools = Set.unmodifiable(allowedTools);

  final String conversationId;
  final String requestId;
  final String assistantMessageId;
  final int callOccurrence;
  final ChatToolCall call;
  final String? selectedAgentId;
  final Set<String> allowedTools;
  final ChatToolEffect effect;
  final bool sourceTainted;
  final String? permissionSnapshot;
  final PendingToolProposalState state;
  bool get claimed => state != PendingToolProposalState.pending;
  final DateTime createdAt;

  bool hasSameIdentity(PendingToolProposal other) =>
      conversationId == other.conversationId &&
      requestId == other.requestId &&
      assistantMessageId == other.assistantMessageId &&
      callOccurrence == other.callOccurrence &&
      call.id == other.call.id &&
      call.name == other.call.name &&
      call.arguments == other.call.arguments &&
      selectedAgentId == other.selectedAgentId &&
      effect == other.effect &&
      sourceTainted == other.sourceTainted &&
      permissionSnapshot == other.permissionSnapshot &&
      state == other.state &&
      allowedTools.length == other.allowedTools.length &&
      allowedTools.containsAll(other.allowedTools) &&
      createdAt == other.createdAt;

  Map<String, dynamic> toJson() => {
    'conversationId': conversationId,
    'requestId': requestId,
    'assistantMessageId': assistantMessageId,
    'callOccurrence': callOccurrence,
    'call': call.toJson(),
    'selectedAgentId': selectedAgentId,
    'allowedTools': allowedTools.toList(growable: false),
    'effect': effect.name,
    'sourceTainted': sourceTainted,
    'permissionSnapshot': permissionSnapshot,
    'state': state.name,
    'createdAt': createdAt.toIso8601String(),
  };

  factory PendingToolProposal.fromJson(Map<dynamic, dynamic> json) =>
      PendingToolProposal(
        conversationId: json['conversationId'].toString(),
        requestId: json['requestId'].toString(),
        assistantMessageId: json['assistantMessageId'].toString(),
        callOccurrence: json['callOccurrence'] as int? ?? 0,
        call: ChatToolCall.fromJson(json['call'] as Map),
        selectedAgentId: json['selectedAgentId']?.toString(),
        allowedTools: (json['allowedTools'] as List? ?? const [])
            .map((value) => value.toString())
            .toSet(),
        effect: ChatToolEffect.values.byName(
          json['effect']?.toString() ?? ChatToolEffect.sensitive.name,
        ),
        sourceTainted: json['sourceTainted'] as bool? ?? true,
        permissionSnapshot: json['permissionSnapshot']?.toString(),
        state: json['state'] == null
            ? (json['claimed'] as bool? ?? false
                  ? PendingToolProposalState.executing
                  : PendingToolProposalState.pending)
            : PendingToolProposalState.values.byName(json['state'].toString()),
        createdAt: DateTime.parse(json['createdAt'].toString()),
      );

  PendingToolProposal claim() => PendingToolProposal(
    conversationId: conversationId,
    requestId: requestId,
    assistantMessageId: assistantMessageId,
    callOccurrence: callOccurrence,
    call: call,
    selectedAgentId: selectedAgentId,
    allowedTools: allowedTools,
    effect: effect,
    sourceTainted: sourceTainted,
    permissionSnapshot: permissionSnapshot,
    createdAt: createdAt,
    state: PendingToolProposalState.executing,
  );
}
