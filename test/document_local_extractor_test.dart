import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/documents/application/local_document_extractor.dart';
import 'package:mobilka/features/documents/domain/document_limits.dart';

import 'support/document_fixtures.dart';

void main() {
  test('local results are deterministic and immutable', () {
    final snapshot = documentSnapshot(utf8.encode('hello,мир'));
    final extractor = LocalDocumentExtractor();
    final first = extractor.extract(snapshot);
    final second = extractor.extract(snapshot);
    expect(first.outputDigest, second.outputDigest);
    expect(first.snapshot, same(snapshot));
    expect(() => first.fragments.clear(), throwsUnsupportedError);
    expect(() => first.warnings.add('changed'), throwsUnsupportedError);
  });

  test('PDF, images and disguised ZIPs are not supported adapters', () {
    for (final path in ['input.pdf', 'input.png', 'input.docx', 'input.xlsx']) {
      expect(
        () => LocalDocumentExtractor().extract(
          documentSnapshot(utf8.encode('not a package'), path: path),
        ),
        throwsA(isA<DocumentException>()),
      );
    }
  });
}
