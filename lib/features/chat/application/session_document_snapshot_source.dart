import 'dart:convert';
import 'dart:typed_data';

import '../../documents/data/bounded_ooxml_package.dart';
import '../../documents/domain/document_limits.dart';
import '../../documents/domain/document_snapshot.dart';
import '../../documents/domain/document_tool_request.dart';
import '../../workspace/application/session_workspace_boundary.dart';
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
      final read = await boundary.readBinary(
        request.path,
        maxBytes: _limits.sourceBytes,
      );
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
        sourcePath: request.path.value,
        sourceIdentity: read.identity,
        bytes: read.bytes,
        expectedSha256: read.sha256,
        limits: _limits,
      );
    });
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
