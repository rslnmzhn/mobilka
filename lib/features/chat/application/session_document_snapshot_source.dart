import 'dart:convert';
import 'dart:typed_data';

import '../../documents/data/bounded_ooxml_package.dart';
import '../../documents/domain/document_limits.dart';
import '../../documents/domain/document_snapshot.dart';
import '../../documents/domain/document_tool_request.dart';
import '../../workspace/application/session_workspace_boundary.dart';
import '../../workspace/domain/session_workspace_path.dart';
import '../../workspace/domain/workspace_models.dart';
import 'chat_tool_runtime.dart';
import 'document_tool_runtime.dart';

final class SessionDocumentSnapshotSource implements DocumentSnapshotSource {
  SessionDocumentSnapshotSource({
    required BinarySessionWorkspaceBoundary Function(
      ChatToolExecutionContext context,
      String sessionKey,
    )
    resolveBoundary,
    DocumentLimits? limits,
  }) : _resolveBoundary = resolveBoundary,
       _limits = limits ?? DocumentLimits();

  final BinarySessionWorkspaceBoundary Function(
    ChatToolExecutionContext context,
    String sessionKey,
  )
  _resolveBoundary;
  final DocumentLimits _limits;

  @override
  Set<DocumentToolInputFormat> get supportedFormats => const {
    DocumentToolInputFormat.csv,
    DocumentToolInputFormat.docx,
    DocumentToolInputFormat.xlsx,
    DocumentToolInputFormat.pdf,
    DocumentToolInputFormat.png,
    DocumentToolInputFormat.jpeg,
  };

  @override
  Future<DocumentSnapshot> capture({
    required DocumentToolRequest request,
    required ChatToolExecutionContext context,
    required String requestId,
  }) async {
    final sessionKey = context.sessionKey;
    final binding = context.workspaceBinding;
    if (sessionKey == null ||
        binding == null ||
        context.conversationId.isEmpty ||
        requestId.isEmpty) {
      throw const DocumentException('missing_document_workspace');
    }
    _validateExtension(request.path.value, request.format);
    final bindingSnapshot = binding.snapshot;
    final boundary = _resolveBoundary(context, sessionKey);
    return boundary.synchronized(() async {
      final rootBefore = await boundary.rootIdentity();
      if (bindingSnapshot.rootIdentity != null &&
          bindingSnapshot.rootIdentity != rootBefore) {
        throw const DocumentException('document_binding_changed');
      }
      final resolved = await _resolveAndReadBinary(
        boundary: boundary,
        requestedPath: request.path,
        expectedSha256: request.sourceHash,
        sessionKey: sessionKey,
        maxBytes: _limits.sourceBytes,
      );
      final read = resolved.read;
      final rootAfter = await boundary.rootIdentity();
      if (read.rootIdentity != rootBefore || rootAfter != rootBefore) {
        throw const DocumentException('document_binding_changed');
      }
      if (read.sha256 != request.sourceHash) {
        throw const DocumentException('document_source_changed');
      }
      _validateMagic(read.bytes, request.format);
      if (request.format == DocumentToolInputFormat.docx ||
          request.format == DocumentToolInputFormat.xlsx) {
        _validateOoxml(read.bytes, request.format);
      }
      return DocumentSnapshot(
        documentId: read.sha256,
        conversationId: context.conversationId,
        requestId: requestId,
        sessionKey: sessionKey,
        binding: bindingSnapshot.withRootIdentity(rootBefore),
        sourcePath: resolved.resolvedPath,
        sourceIdentity: read.identity,
        bytes: read.bytes,
        expectedSha256: read.sha256,
        limits: _limits,
      );
    });
  }

  Future<({WorkspaceBinaryReadResult read, String resolvedPath})>
  _resolveAndReadBinary({
    required BinarySessionWorkspaceBoundary boundary,
    required SessionWorkspacePath requestedPath,
    required String expectedSha256,
    required String sessionKey,
    required int maxBytes,
  }) async {
    // 1. Try reading the exact requested path directly.
    try {
      final direct = await boundary.readBinary(
        requestedPath,
        maxBytes: maxBytes,
      );
      return (read: direct, resolvedPath: requestedPath.value);
    } on WorkspaceBoundaryException catch (error) {
      if (error.code != 'not_found') rethrow;
    }

    // 2. If caller passed 'sessions/<sessionKey>/...', strip the prefix.
    final sessionPrefix = 'sessions/$sessionKey/';
    if (requestedPath.value.startsWith(sessionPrefix)) {
      final stripped = requestedPath.value.substring(sessionPrefix.length);
      try {
        final parsed = SessionWorkspacePath.parse(stripped);
        final read = await boundary.readBinary(parsed, maxBytes: maxBytes);
        return (read: read, resolvedPath: parsed.value);
      } on Object {
        // Fall through to next fallback.
      }
    }

    // 3. If caller passed a bare filename (e.g. 'Чек.pdf'), check inside 'artifacts/'.
    if (requestedPath.components.length == 1) {
      try {
        final artifactPath = SessionWorkspacePath.parse(
          'artifacts/${requestedPath.value}',
        );
        final read = await boundary.readBinary(
          artifactPath,
          maxBytes: maxBytes,
        );
        return (read: read, resolvedPath: artifactPath.value);
      } on Object {
        // Fall through to listing fallback.
      }
    }

    // 4. Search session workspace entries for matching SHA-256 hash or filename.
    try {
      final entries = await boundary.list(
        SessionWorkspacePath.parse('', allowRoot: true),
        recursive: true,
      );
      // First: check files matching the expected SHA-256 hash
      for (final entry in entries) {
        if (entry.type != WorkspaceEntryType.file) continue;
        try {
          final entryPath = SessionWorkspacePath.parse(entry.path);
          final read = await boundary.readBinary(entryPath, maxBytes: maxBytes);
          if (read.sha256 == expectedSha256) {
            return (read: read, resolvedPath: entry.path);
          }
        } on Object {
          // Continue scanning
        }
      }
      // Second: check files matching the requested leaf filename
      final requestedName = requestedPath.components.last.toLowerCase();
      for (final entry in entries) {
        if (entry.type != WorkspaceEntryType.file) continue;
        final entryName = entry.path.split('/').last.toLowerCase();
        if (entryName == requestedName) {
          try {
            final entryPath = SessionWorkspacePath.parse(entry.path);
            final read = await boundary.readBinary(
              entryPath,
              maxBytes: maxBytes,
            );
            return (read: read, resolvedPath: entry.path);
          } on Object {
            // Continue scanning
          }
        }
      }
    } on Object {
      // Fall through to throw not_found
    }

    throw const WorkspaceBoundaryException('not_found');
  }

  static void _validateExtension(String path, DocumentToolInputFormat format) {
    final extension = path.toLowerCase().split('.').last;
    final expected = format == DocumentToolInputFormat.jpeg
        ? const {'jpg', 'jpeg'}
        : {format.name};
    if (!expected.contains(extension)) {
      throw const DocumentException('document_format_mismatch');
    }
  }

  static void _validateMagic(List<int> bytes, DocumentToolInputFormat format) {
    bool starts(List<int> magic) =>
        bytes.length >= magic.length &&
        Iterable<int>.generate(magic.length).every((i) => bytes[i] == magic[i]);
    final valid = switch (format) {
      DocumentToolInputFormat.csv => _validUtf8(bytes),
      DocumentToolInputFormat.docx ||
      DocumentToolInputFormat.xlsx => starts(const [0x50, 0x4b, 0x03, 0x04]),
      DocumentToolInputFormat.pdf => starts(const [0x25, 0x50, 0x44, 0x46]),
      DocumentToolInputFormat.png => starts(const [
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ]),
      DocumentToolInputFormat.jpeg => starts(const [0xff, 0xd8, 0xff]),
    };
    if (!valid) throw const DocumentException('document_format_mismatch');
  }

  static bool _validUtf8(List<int> bytes) {
    try {
      utf8.decode(bytes, allowMalformed: false);
      return true;
    } on FormatException {
      return false;
    }
  }

  void _validateOoxml(List<int> bytes, DocumentToolInputFormat format) {
    final package = BoundedOoxmlPackage.read(
      Uint8List.fromList(bytes),
      _limits,
    );
    final types = package.parts['[Content_Types].xml'];
    if (types == null) {
      throw const DocumentException('document_format_mismatch');
    }
    final text = utf8.decode(types, allowMalformed: false);
    final required = format == DocumentToolInputFormat.docx
        ? 'wordprocessingml.document.main+xml'
        : 'spreadsheetml.sheet.main+xml';
    if (!text.contains(required)) {
      throw const DocumentException('document_format_mismatch');
    }
  }
}
