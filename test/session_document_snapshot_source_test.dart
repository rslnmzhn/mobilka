import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/core/workspace/workspace_binding.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart';
import 'package:mobilka/features/chat/application/session_document_snapshot_source.dart';
import 'package:mobilka/features/documents/domain/document_limits.dart';
import 'package:mobilka/features/documents/domain/document_tool_request.dart';
import 'package:mobilka/features/workspace/application/session_workspace_boundary.dart';
import 'package:mobilka/features/workspace/domain/session_workspace_path.dart';
import 'package:mobilka/features/workspace/domain/workspace_models.dart';

void main() {
  test(
    'captures immutable bytes with request and workspace ownership',
    () async {
      final bytes = utf8.encode('a,b\n1,2');
      final boundary = _BinaryBoundary(bytes);
      final source = SessionDocumentSnapshotSource(
        resolveBoundary: (_, _) => boundary,
      );
      final snapshot = await source.capture(
        request: _request('input.csv', workspaceHash(bytes), 'csv'),
        context: _context(),
        requestId: 'request',
      );

      bytes[0] = 0;
      expect(utf8.decode(snapshot.bytes), 'a,b\n1,2');
      expect(() => snapshot.bytes[0] = 0, throwsUnsupportedError);
      expect(snapshot.conversationId, 'conversation');
      expect(snapshot.requestId, 'request');
      expect(snapshot.sessionKey, 'session');
      expect(snapshot.binding.rootIdentity, 'root');
      expect(snapshot.sourceIdentity, 'file');
      expect(source.supportedFormats, DocumentToolInputFormat.values.toSet());
    },
  );

  test('rejects changed roots, hashes, extension and magic', () async {
    Future<void> rejects(
      _BinaryBoundary boundary,
      String path,
      String hash,
      String format,
    ) async {
      final source = SessionDocumentSnapshotSource(
        resolveBoundary: (_, _) => boundary,
      );
      await expectLater(
        source.capture(
          request: _request(path, hash, format),
          context: _context(),
          requestId: 'request',
        ),
        throwsA(isA<DocumentException>()),
      );
    }

    final csv = utf8.encode('a,b');
    await rejects(
      _BinaryBoundary(csv, roots: ['root', 'changed']),
      'input.csv',
      workspaceHash(csv),
      'csv',
    );
    await rejects(
      _BinaryBoundary(csv),
      'input.csv',
      List.filled(64, '0').join(),
      'csv',
    );
    await rejects(_BinaryBoundary(csv), 'input.pdf', workspaceHash(csv), 'pdf');
    expect(
      () => _request('input.pdf', workspaceHash(csv), 'csv'),
      throwsA(isA<DocumentException>()),
    );
  });

  test('passes the configured source limit to the binary boundary', () async {
    final bytes = utf8.encode('a');
    final boundary = _BinaryBoundary(bytes);
    final source = SessionDocumentSnapshotSource(
      resolveBoundary: (_, _) => boundary,
      limits: DocumentLimits(sourceBytes: 7),
    );
    await source.capture(
      request: _request('input.csv', workspaceHash(bytes), 'csv'),
      context: _context(),
      requestId: 'request',
    );
    expect(boundary.maximum, 7);
  });
}

DocumentToolRequest _request(String path, String hash, String format) =>
    DocumentToolRequest.parse(
      'extract_document',
      jsonEncode({'path': path, 'source_sha256': hash, 'format': format}),
    );

ChatToolExecutionContext _context() => const ChatToolExecutionContext(
  conversationId: 'conversation',
  sessionKey: 'session',
  workspaceBinding: TestWorkspaceBinding(
    testSnapshot: WorkspaceBindingSnapshot(
      isContentUri: false,
      value: 'workspace',
      identity: 'grant',
      rootIdentity: 'root',
    ),
  ),
);

final class _BinaryBoundary implements BinarySessionWorkspaceBoundary {
  _BinaryBoundary(this.source, {this.roots = const ['root']});

  final List<int> source;
  final List<String> roots;
  var rootReads = 0;
  int? maximum;

  @override
  Future<String> rootIdentity() async =>
      roots[rootReads++ < roots.length ? rootReads - 1 : roots.length - 1];

  @override
  Future<T> synchronized<T>(Future<T> Function() action) => action();

  @override
  Future<WorkspaceBinaryReadResult> readBinary(
    SessionWorkspacePath path, {
    required int maxBytes,
  }) async {
    maximum = maxBytes;
    if (source.length > maxBytes) {
      throw const FormatException('workspace_file_too_large');
    }
    return WorkspaceBinaryReadResult(
      bytes: source,
      size: source.length,
      sha256: workspaceHash(source),
      identity: 'file',
      rootIdentity: roots.first,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
