import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/core/workspace/workspace_binding.dart';
import 'package:mobilka/features/documents/domain/document_limits.dart';
import 'package:mobilka/features/documents/domain/document_snapshot.dart';

import 'support/document_fixtures.dart';

void main() {
  test('snapshot owns immutable bytes and stable provenance', () {
    final bytes = utf8.encode('Привет');
    final snapshot = documentSnapshot(bytes);
    final hash = snapshot.sha256Digest;
    bytes[0] = 0;
    expect(utf8.decode(snapshot.bytes), 'Привет');
    expect(snapshot.sha256Digest, hash);
    expect(snapshot.conversationId, 'conversation');
    expect(snapshot.requestId, 'request');
    expect(snapshot.sourcePath.value, 'input.csv');
    expect(() => snapshot.bytes[0] = 0, throwsUnsupportedError);
    expect(
      () => snapshot.bytes.buffer.asUint8List()[0] = 0,
      throwsUnsupportedError,
    );
  });

  test('snapshot rejects traversal, invalid bytes and oversize sources', () {
    expect(
      () => documentSnapshot([], path: '../secret.csv'),
      throwsFormatException,
    );
    expect(() => documentSnapshot([256]), throwsA(isA<DocumentException>()));
    expect(
      () => documentSnapshot(List.filled(10485761, 0)),
      throwsA(isA<DocumentException>()),
    );
  });

  test('limits can only be tightened', () {
    expect(DocumentLimits(rows: 1).rows, 1);
    expect(
      () => DocumentLimits(rows: 10001),
      throwsA(isA<DocumentException>()),
    );
    expect(
      () => DocumentLimits(xmlDepth: 0),
      throwsA(isA<DocumentException>()),
    );
  });

  test(
    'snapshot requires stable ownership, root identity and matching digest',
    () {
      DocumentSnapshot create({
        String request = 'request',
        String? root = 'root',
        String? digest,
      }) => DocumentSnapshot(
        documentId: 'document',
        conversationId: 'conversation',
        requestId: request,
        sessionKey: 'session',
        binding: WorkspaceBindingSnapshot(
          isContentUri: false,
          value: 'root',
          identity: 'grant',
          rootIdentity: root,
        ),
        sourcePath: 'input.csv',
        sourceIdentity: 'file',
        bytes: [1],
        expectedSha256: digest,
      );
      expect(() => create(request: ''), throwsA(isA<DocumentException>()));
      expect(() => create(root: null), throwsA(isA<DocumentException>()));
      expect(
        () => create(digest: 'incorrect'),
        throwsA(isA<DocumentException>()),
      );
    },
  );
}
