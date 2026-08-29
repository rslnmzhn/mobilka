import '../../memory/application/workspace_paths.dart';

enum PendingSkillProposalState { pending, executing }

class PendingSkillProposal {
  PendingSkillProposal({
    required this.conversationId,
    required this.requestId,
    required this.assistantMessageId,
    required this.name,
    required this.oldContent,
    required this.proposedContent,
    required this.expectedHash,
    required this.sourceDerived,
    required this.provenanceSummary,
    required this.warnings,
    required this.permissionSnapshot,
    this.workspaceBindingSnapshot,
    required this.selectedAgentId,
    required this.createdAt,
    this.state = PendingSkillProposalState.pending,
  });

  final String conversationId;
  final String requestId;
  final String assistantMessageId;
  final String name;
  final String? oldContent;
  final String proposedContent;
  final String? expectedHash;
  final bool sourceDerived;
  final String provenanceSummary;
  final List<String> warnings;
  final String? permissionSnapshot;
  final WorkspaceBindingSnapshot? workspaceBindingSnapshot;
  final String? selectedAgentId;
  final DateTime createdAt;
  final PendingSkillProposalState state;
  bool get isUpdate => oldContent != null;

  PendingSkillProposal claim() => _copy(PendingSkillProposalState.executing);

  PendingSkillProposal _copy(PendingSkillProposalState value) =>
      PendingSkillProposal(
        conversationId: conversationId,
        requestId: requestId,
        assistantMessageId: assistantMessageId,
        name: name,
        oldContent: oldContent,
        proposedContent: proposedContent,
        expectedHash: expectedHash,
        sourceDerived: sourceDerived,
        provenanceSummary: provenanceSummary,
        warnings: warnings,
        permissionSnapshot: permissionSnapshot,
        workspaceBindingSnapshot: workspaceBindingSnapshot,
        selectedAgentId: selectedAgentId,
        createdAt: createdAt,
        state: value,
      );

  bool sameIdentity(PendingSkillProposal other) =>
      conversationId == other.conversationId &&
      requestId == other.requestId &&
      assistantMessageId == other.assistantMessageId &&
      name == other.name &&
      oldContent == other.oldContent &&
      proposedContent == other.proposedContent &&
      expectedHash == other.expectedHash &&
      sourceDerived == other.sourceDerived &&
      provenanceSummary == other.provenanceSummary &&
      permissionSnapshot == other.permissionSnapshot &&
      workspaceBindingSnapshot?.identity ==
          other.workspaceBindingSnapshot?.identity &&
      selectedAgentId == other.selectedAgentId &&
      createdAt == other.createdAt &&
      state == other.state;

  Map<String, dynamic> toJson() => {
    'conversationId': conversationId,
    'requestId': requestId,
    'assistantMessageId': assistantMessageId,
    'name': name,
    'oldContent': oldContent,
    'proposedContent': proposedContent,
    'expectedHash': expectedHash,
    'sourceDerived': sourceDerived,
    'provenanceSummary': provenanceSummary,
    'warnings': warnings,
    'permissionSnapshot': permissionSnapshot,
    'workspaceBindingSnapshot': workspaceBindingSnapshot?.toJson(),
    'selectedAgentId': selectedAgentId,
    'createdAt': createdAt.toIso8601String(),
    'state': state.name,
  };

  factory PendingSkillProposal.fromJson(Map<dynamic, dynamic> json) =>
      PendingSkillProposal(
        conversationId: json['conversationId'].toString(),
        requestId: json['requestId'].toString(),
        assistantMessageId: json['assistantMessageId'].toString(),
        name: json['name'].toString(),
        oldContent: json['oldContent']?.toString(),
        proposedContent: json['proposedContent'].toString(),
        expectedHash: json['expectedHash']?.toString(),
        sourceDerived: json['sourceDerived'] as bool? ?? true,
        provenanceSummary:
            json['provenanceSummary']?.toString() ?? 'legacy_unknown',
        warnings: (json['warnings'] as List? ?? const [])
            .map((value) => value.toString())
            .toList(growable: false),
        permissionSnapshot: json['permissionSnapshot']?.toString(),
        workspaceBindingSnapshot: json['workspaceBindingSnapshot'] is Map
            ? WorkspaceBindingSnapshot.fromJson(
                json['workspaceBindingSnapshot'] as Map,
              )
            : null,
        selectedAgentId: json['selectedAgentId']?.toString(),
        createdAt: DateTime.parse(json['createdAt'].toString()),
        state: PendingSkillProposalState.values.byName(
          json['state']?.toString() ?? 'pending',
        ),
      );
}
