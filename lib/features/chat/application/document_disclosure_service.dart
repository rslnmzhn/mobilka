import 'dart:convert';

import '../../documents/application/document_tool_service.dart';
import '../../documents/domain/document_limits.dart';
import '../domain/chat_message.dart';
import '../domain/pending_document_proposal.dart';
import 'chat_tool_runtime.dart';
import 'document_tool_runtime.dart';

final class DocumentDisclosureService {
  DocumentDisclosureService({required this.runtime, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DocumentToolRuntime runtime;
  final DateTime Function() _now;
  static const rejectionPayload = '{"error":"document_disclosure_rejected"}';

  Future<PendingDocumentProposal> prepare({
    required ChatToolCall call,
    required ChatToolExecutionContext context,
    required String requestId,
    required String assistantMessageId,
    required int toolCallIndex,
    required int callOccurrence,
    required String selectedAgentId,
    required Set<String> allowedTools,
  }) async {
    final permissions = Set<String>.of(allowedTools);
    final permissionSnapshot = context.workspaceBinding?.permissionSnapshot;
    final result = await runtime.prepareLocalResult(
      call: call,
      allowedTools: permissions,
      context: context,
      requestId: requestId,
    );
    if (permissionSnapshot == null ||
        context.workspaceBinding?.permissionSnapshot != permissionSnapshot ||
        !_samePermissions(permissions, allowedTools)) {
      throw const DocumentException('document_authorization_changed');
    }
    final source = result.snapshot;
    final payload = _payload(result);
    final created = _now().toUtc();
    return PendingDocumentProposal.fromJson({
      'version': 1,
      'conversationId': context.conversationId,
      'requestId': requestId,
      'assistantMessageId': assistantMessageId,
      'toolCallId': call.id,
      'toolCallIndex': toolCallIndex,
      'callOccurrence': callOccurrence,
      'toolName': call.name,
      'arguments': call.arguments,
      'selectedAgentId': selectedAgentId,
      'allowedTools': permissions.toList()..sort(),
      'permissionSnapshot': permissionSnapshot,
      'sessionKey': source.sessionKey,
      'binding': jsonEncode(source.binding.toJson()),
      'documentId': source.documentId,
      'sourceIdentity': source.sourceIdentity,
      'sourcePath': source.sourcePath.value,
      'sourceHash': source.sha256Digest,
      'optionsIdentity': result.optionsIdentity,
      'outputDigest': result.outputDigest,
      'payload': payload,
      'payloadSha256': PendingDocumentProposal.digest(payload),
      'createdAt': created.toIso8601String(),
      'expiresAt': created.add(const Duration(minutes: 15)).toIso8601String(),
      'status': DocumentProposalStatus.pending.name,
      'claimToken': null,
      'claimedAt': null,
    });
  }

  Future<String> confirm({
    required PendingDocumentProposal proposal,
    required String claimToken,
    required ChatToolCall call,
    required ChatToolExecutionContext context,
    required String requestId,
    required String assistantMessageId,
    required int toolCallIndex,
    required int callOccurrence,
    required String selectedAgentId,
    required Set<String> allowedTools,
  }) async {
    void validate() {
      final now = _now().toUtc();
      final data = proposal.toJson();
      if (proposal.status != DocumentProposalStatus.claimed ||
          proposal.claimToken != claimToken ||
          now.isBefore(proposal.createdAt) ||
          !now.isBefore(proposal.expiresAt) ||
          proposal.conversationId != context.conversationId ||
          proposal.requestId != requestId ||
          proposal.assistantMessageId != assistantMessageId ||
          proposal.toolCallIndex != toolCallIndex ||
          proposal.callOccurrence != callOccurrence ||
          proposal.toolCallId != call.id ||
          proposal.toolName != call.name ||
          proposal.arguments != call.arguments ||
          proposal.selectedAgentId != selectedAgentId ||
          !_samePermissions(proposal.allowedTools, allowedTools) ||
          data['sessionKey'] != context.sessionKey ||
          data['permissionSnapshot'] !=
              context.workspaceBinding?.permissionSnapshot ||
          data['binding'] !=
              jsonEncode(context.workspaceBinding?.snapshot.toJson())) {
        throw const DocumentException('document_disclosure_stale');
      }
    }

    validate();
    final fresh = await prepare(
      call: call,
      context: context,
      requestId: requestId,
      assistantMessageId: assistantMessageId,
      toolCallIndex: toolCallIndex,
      callOccurrence: callOccurrence,
      selectedAgentId: selectedAgentId,
      allowedTools: allowedTools,
    );
    validate();
    final oldData = proposal.toJson();
    final newData = fresh.toJson();
    for (final key in oldData.keys) {
      if (const {
        'createdAt',
        'expiresAt',
        'status',
        'claimToken',
        'claimedAt',
      }.contains(key)) {
        continue;
      }
      if (jsonEncode(oldData[key]) != jsonEncode(newData[key])) {
        throw const DocumentException('document_disclosure_stale');
      }
    }
    return proposal.payload;
  }

  String reject() => rejectionPayload;

  static bool _samePermissions(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);

  static String _payload(LocalDocumentToolResult result) {
    final Map<String, Object?> content = switch (result) {
      ExtractedDocumentToolResult(:final extraction) => {
        'format': extraction.format.name,
        'fragments': extraction.fragments.map((f) => f.digestFields).toList(),
        'warnings': extraction.warnings.toList()..sort(),
      },
      NativeDocumentToolResult(:final extraction) => {
        'pages': extraction.pages.map((p) => [p.page, p.ocr, p.text]).toList(),
      },
    };
    final payload = jsonEncode({
      'provenance': 'local_document',
      'source_sha256': result.snapshot.sha256Digest,
      'options_identity': result.optionsIdentity,
      'output_digest': result.outputDigest,
      ...content,
    });
    if (payload.length > PendingDocumentProposal.maxPayloadBytes ||
        utf8.encode(payload).length > PendingDocumentProposal.maxPayloadBytes) {
      throw const DocumentException('document_disclosure_limit');
    }
    return payload;
  }
}
