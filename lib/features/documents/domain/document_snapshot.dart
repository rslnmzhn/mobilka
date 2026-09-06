import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../../core/workspace/workspace_binding.dart';
import '../../workspace/domain/session_workspace_path.dart';
import 'document_limits.dart';

final class DocumentSnapshot {
  factory DocumentSnapshot({
    required String documentId,
    required String conversationId,
    required String requestId,
    required String sessionKey,
    required WorkspaceBindingSnapshot binding,
    required String sourcePath,
    required String sourceIdentity,
    required List<int> bytes,
    String? expectedSha256,
    DocumentLimits? limits,
  }) {
    final policy = limits ?? DocumentLimits();
    for (final identity in [
      documentId,
      conversationId,
      requestId,
      sourceIdentity,
    ]) {
      if (identity.isEmpty ||
          utf8.encode(identity).length > 4096 ||
          identity.runes.any((r) => r < 32 || r == 127)) {
        throw const DocumentException('invalid_document_identity');
      }
    }
    final session = SessionWorkspacePath.parse(sessionKey);
    if (session.components.length != 1) {
      throw const DocumentException('invalid_document_session');
    }
    final location = WorkspaceBindingSnapshot.fromJson(binding.toJson());
    if (location.rootIdentity == null) {
      throw const DocumentException('missing_document_root_identity');
    }
    final path = SessionWorkspacePath.parse(sourcePath);
    if (bytes.length > policy.sourceBytes) {
      throw const DocumentException('document_source_limit');
    }
    if (bytes.any((byte) => byte < 0 || byte > 255)) {
      throw const DocumentException('invalid_document_bytes');
    }
    final copy = Uint8List.fromList(bytes).asUnmodifiableView();
    final digest = sha256.convert(copy).toString();
    if (expectedSha256 != null && expectedSha256 != digest) {
      throw const DocumentException('document_source_changed');
    }
    return DocumentSnapshot._(
      documentId,
      conversationId,
      requestId,
      sessionKey,
      location,
      path,
      sourceIdentity,
      copy,
      digest,
    );
  }

  DocumentSnapshot._(
    this.documentId,
    this.conversationId,
    this.requestId,
    this.sessionKey,
    this.binding,
    this.sourcePath,
    this.sourceIdentity,
    this.bytes,
    this.sha256Digest,
  );

  final String documentId;
  final String conversationId;
  final String requestId;
  final String sessionKey;
  final WorkspaceBindingSnapshot binding;
  final SessionWorkspacePath sourcePath;
  final String sourceIdentity;
  final Uint8List bytes;
  final String sha256Digest;
  int get byteCount => bytes.length;
}
