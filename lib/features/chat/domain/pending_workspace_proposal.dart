import 'dart:convert';

import '../../../core/workspace/workspace_binding.dart';
import '../../workspace/domain/session_workspace_path.dart';
import '../../workspace/domain/workspace_models.dart';
import '../../workspace/domain/workspace_operation_identity.dart';
import 'workspace_proposal_context.dart';

enum WorkspaceProposalStatus { pending, executing }

final class PendingWorkspaceProposal {
  PendingWorkspaceProposal({
    required this.conversationId,
    required this.requestId,
    required this.assistantMessageId,
    required this.toolCallId,
    required this.callOccurrence,
    required this.toolCallIndex,
    required this.operation,
    required this.path,
    this.destination,
    this.proposedContent,
    this.proposedContentHash,
    this.patch,
    required this.preview,
    required this.previewHash,
    this.sourceIdentity,
    this.sourceHash,
    this.sourceType,
    this.targetIdentity,
    this.targetHash,
    this.targetType,
    required this.targetMissing,
    required this.sessionKey,
    required Set<String> allowedTools,
    required this.selectedAgentId,
    required this.workspaceBindingSnapshot,
    required this.createdAt,
    required this.expiresAt,
    this.status = WorkspaceProposalStatus.pending,
    this.claimToken,
  }) : context = WorkspaceProposalContext(
         conversationId: conversationId,
         requestId: requestId,
         assistantMessageId: assistantMessageId,
         toolCallId: toolCallId,
         callOccurrence: callOccurrence,
         toolCallIndex: toolCallIndex,
         selectedAgentId: selectedAgentId,
         allowedTools: allowedTools,
         ownerToken: workspaceHash(
           utf8.encode(
             '$conversationId\u0000$requestId\u0000$toolCallId\u0000$callOccurrence',
           ),
         ),
       ),
       operationIdentity = WorkspaceOperationIdentity(
         operationId: workspaceHash(
           utf8.encode('$requestId\u0000$toolCallId\u0000$callOccurrence'),
         ),
         sessionKey: sessionKey,
         rootIdentity:
             workspaceBindingSnapshot.rootIdentity ??
             (throw const FormatException('workspace_root_identity_required')),
         operation: operation,
         path: path,
         destination: destination,
         proposedContentHash: proposedContentHash,
         sourceIdentity: sourceIdentity,
         sourceHash: sourceHash,
         sourceType: sourceType,
         targetIdentity: targetIdentity,
         targetHash: targetHash,
         targetType: targetType,
         targetMissing: targetMissing,
       ),
       allowedTools = Set.unmodifiable(allowedTools) {
    _validate();
  }

  final String conversationId;
  final String requestId;
  final String assistantMessageId;
  final String toolCallId;
  final int callOccurrence;
  final int toolCallIndex;
  final String operation;
  final String path;
  final String? destination;
  final String? proposedContent;
  final String? proposedContentHash;
  final String? patch;
  final String preview;
  final String previewHash;
  final String? sourceIdentity;
  final String? sourceHash;
  final String? sourceType;
  final String? targetIdentity;
  final String? targetHash;
  final String? targetType;
  final bool targetMissing;
  final String sessionKey;
  final Set<String> allowedTools;
  final String selectedAgentId;
  final WorkspaceBindingSnapshot workspaceBindingSnapshot;
  final DateTime createdAt;
  final DateTime expiresAt;
  final WorkspaceProposalStatus status;
  final String? claimToken;
  final WorkspaceProposalContext context;
  final WorkspaceOperationIdentity operationIdentity;

  WorkspaceOperationIdentity get identity => operationIdentity;

  bool hasSameIdentity(PendingWorkspaceProposal other) =>
      conversationId == other.conversationId &&
      requestId == other.requestId &&
      assistantMessageId == other.assistantMessageId &&
      toolCallId == other.toolCallId &&
      callOccurrence == other.callOccurrence &&
      toolCallIndex == other.toolCallIndex &&
      preview == other.preview &&
      previewHash == other.previewHash &&
      operation == other.operation &&
      path == other.path &&
      destination == other.destination &&
      proposedContentHash == other.proposedContentHash &&
      patch == other.patch &&
      sourceIdentity == other.sourceIdentity &&
      sourceHash == other.sourceHash &&
      sourceType == other.sourceType &&
      targetIdentity == other.targetIdentity &&
      targetHash == other.targetHash &&
      targetType == other.targetType &&
      targetMissing == other.targetMissing &&
      sessionKey == other.sessionKey &&
      _sameSet(allowedTools, other.allowedTools) &&
      selectedAgentId == other.selectedAgentId &&
      workspaceBindingSnapshot.identity ==
          other.workspaceBindingSnapshot.identity &&
      workspaceBindingSnapshot.rootIdentity ==
          other.workspaceBindingSnapshot.rootIdentity &&
      createdAt == other.createdAt &&
      expiresAt == other.expiresAt &&
      status == other.status &&
      claimToken == other.claimToken;

  PendingWorkspaceProposal executing([
    String token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  ]) => _copy(WorkspaceProposalStatus.executing, token);

  PendingWorkspaceProposal pending() =>
      _copy(WorkspaceProposalStatus.pending, null);

  PendingWorkspaceProposal _copy(WorkspaceProposalStatus next, String? token) =>
      PendingWorkspaceProposal(
        conversationId: conversationId,
        requestId: requestId,
        assistantMessageId: assistantMessageId,
        toolCallId: toolCallId,
        callOccurrence: callOccurrence,
        toolCallIndex: toolCallIndex,
        operation: operation,
        path: path,
        destination: destination,
        proposedContent: proposedContent,
        proposedContentHash: proposedContentHash,
        patch: patch,
        preview: preview,
        previewHash: previewHash,
        sourceIdentity: sourceIdentity,
        sourceHash: sourceHash,
        sourceType: sourceType,
        targetIdentity: targetIdentity,
        targetHash: targetHash,
        targetType: targetType,
        targetMissing: targetMissing,
        sessionKey: sessionKey,
        allowedTools: allowedTools,
        selectedAgentId: selectedAgentId,
        workspaceBindingSnapshot: workspaceBindingSnapshot,
        createdAt: createdAt,
        expiresAt: expiresAt,
        status: next,
        claimToken: token,
      );

  Map<String, Object?> toJson() => {
    'context': context.toJson(),
    'operationIdentity': operationIdentity.toJson(),
    'proposedContent': proposedContent,
    'patch': patch,
    'preview': preview,
    'previewHash': previewHash,
    'workspaceBindingSnapshot': workspaceBindingSnapshot.toJson(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'status': status.name,
    'claimToken': claimToken,
  };

  factory PendingWorkspaceProposal.fromJson(Map<dynamic, dynamic> source) {
    final json = Map<String, Object?>.from(source);
    const keys = {
      'context',
      'operationIdentity',
      'proposedContent',
      'patch',
      'preview',
      'previewHash',
      'workspaceBindingSnapshot',
      'createdAt',
      'expiresAt',
      'status',
      'claimToken',
    };
    if (json.keys.any((key) => !keys.contains(key)) ||
        json.keys.length != keys.length) {
      throw const FormatException('invalid_workspace_proposal_fields');
    }
    String requiredString(String key, {int max = 1024}) {
      final value = json[key];
      if (value is! String || value.isEmpty || value.length > max) {
        throw const FormatException('invalid_workspace_proposal');
      }
      return value;
    }

    String? optionalString(String key, {int max = workspaceMaxTextBytes}) {
      final value = json[key];
      if (value != null && (value is! String || value.length > max)) {
        throw const FormatException('invalid_workspace_proposal');
      }
      return value as String?;
    }

    final rawContext = json['context'];
    final rawOperation = json['operationIdentity'];
    final snapshot = json['workspaceBindingSnapshot'];
    if (rawContext is! Map || rawOperation is! Map || snapshot is! Map) {
      throw const FormatException('invalid_workspace_proposal');
    }
    final context = WorkspaceProposalContext.fromJson(rawContext);
    final operation = WorkspaceOperationIdentity.fromJson(rawOperation);
    return PendingWorkspaceProposal(
      conversationId: context.conversationId,
      requestId: context.requestId,
      assistantMessageId: context.assistantMessageId,
      toolCallId: context.toolCallId,
      callOccurrence: context.callOccurrence,
      toolCallIndex: context.toolCallIndex,
      operation: operation.operation,
      path: operation.path,
      destination: operation.destination,
      proposedContent: optionalString('proposedContent'),
      proposedContentHash: operation.proposedContentHash,
      patch: optionalString('patch', max: workspaceMaxPatchBytes),
      preview: requiredString('preview', max: workspaceMaxPreviewBytes),
      previewHash: requiredString('previewHash', max: 64),
      sourceIdentity: operation.sourceIdentity,
      sourceHash: operation.sourceHash,
      sourceType: operation.sourceType,
      targetIdentity: operation.targetIdentity,
      targetHash: operation.targetHash,
      targetType: operation.targetType,
      targetMissing: operation.targetMissing,
      sessionKey: operation.sessionKey,
      allowedTools: context.allowedTools,
      selectedAgentId: context.selectedAgentId,
      workspaceBindingSnapshot: WorkspaceBindingSnapshot.fromJson(snapshot),
      createdAt: DateTime.parse(requiredString('createdAt')),
      expiresAt: DateTime.parse(requiredString('expiresAt')),
      status: WorkspaceProposalStatus.values.byName(requiredString('status')),
      claimToken: optionalString('claimToken', max: 64),
    );
  }

  static PendingWorkspaceProposal? tryFromJson(Map<dynamic, dynamic> source) {
    try {
      return PendingWorkspaceProposal.fromJson(source);
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    } on TypeError {
      return null;
    }
  }

  void _validate() {
    if (context.ownerToken !=
            workspaceHash(
              utf8.encode(
                '$conversationId\u0000$requestId\u0000$toolCallId\u0000$callOccurrence',
              ),
            ) ||
        operationIdentity.rootIdentity !=
            workspaceBindingSnapshot.rootIdentity) {
      throw const FormatException('invalid_workspace_identity_envelope');
    }
    if (!workspaceMutationTools.contains(operation) ||
        callOccurrence < 0 ||
        toolCallIndex < 0) {
      throw const FormatException('invalid_workspace_proposal');
    }
    if (status == WorkspaceProposalStatus.pending && claimToken != null ||
        (claimToken != null &&
            !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(claimToken!))) {
      throw const FormatException('invalid_workspace_claim');
    }
    final compatibilityAlias =
        operation == 'write_file' &&
        path == 'session.md' &&
        allowedTools.contains('write_session_notes');
    if ((!allowedTools.contains(operation) && !compatibilityAlias) ||
        selectedAgentId.isEmpty) {
      throw const FormatException('invalid_workspace_permission_snapshot');
    }
    SessionWorkspacePath.parse(path);
    if (destination != null) SessionWorkspacePath.parse(destination!);
    if (_isArtifactPath(path) ||
        (destination != null && _isArtifactPath(destination!))) {
      throw const FormatException('workspace_artifacts_read_only');
    }
    if (previewHash != workspaceHash(utf8.encode(preview))) {
      throw const FormatException('invalid_workspace_preview_hash');
    }
    if (utf8.encode(preview).length > workspaceMaxPreviewBytes ||
        (proposedContent != null &&
            utf8.encode(proposedContent!).length > workspaceMaxTextBytes) ||
        (patch != null &&
            utf8.encode(patch!).length > workspaceMaxPatchBytes) ||
        (proposedContent == null) != (proposedContentHash == null) ||
        (proposedContent != null &&
            proposedContentHash !=
                workspaceHash(utf8.encode(proposedContent!)))) {
      throw const FormatException('invalid_workspace_result_hash');
    }
    final writesContent =
        operation == 'write_file' || operation == 'apply_patch';
    if (writesContent != (proposedContent != null) ||
        (operation == 'apply_patch') != (patch != null) ||
        (operation == 'move_file') != (destination != null) ||
        (operation == 'move_file' && !targetMissing)) {
      throw const FormatException('invalid_workspace_operation_snapshot');
    }
    if (expiresAt.isBefore(createdAt) ||
        expiresAt.difference(createdAt) > const Duration(hours: 1)) {
      throw const FormatException('invalid_workspace_proposal_expiry');
    }
    if (utf8.encode(jsonEncode(toJson())).length > workspaceMaxProposalBytes) {
      throw const FormatException('workspace_proposal_too_large');
    }
  }
}

bool _isArtifactPath(String path) {
  final portable = path.toLowerCase();
  return portable == 'artifacts' || portable.startsWith('artifacts/');
}

const workspaceMutationTools = {
  'write_file',
  'apply_patch',
  'move_file',
  'delete_file',
  'make_directory',
};

bool _sameSet(Set<String> first, Set<String> second) =>
    first.length == second.length && first.containsAll(second);
