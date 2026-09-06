import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/documents/application/local_document_extractor.dart';
import 'package:mobilka/features/documents/domain/document_limits.dart';

import 'support/document_fixtures.dart';

void main() {
  test(
    'CSV preserves Unicode, quoting, newlines and trailing empty fields',
    () {
      final result = LocalDocumentExtractor().extract(
        documentSnapshot(
          utf8.encode('\ufeff"Привет, мир","say ""hello"""\r\n"a\nb",'),
        ),
      );
      expect(result.fragments.map((f) => f.text), [
        'Привет, мир',
        'say "hello"',
        'a\nb',
        '',
      ]);
      expect(result.fragments.last.row, 2);
      expect(result.fragments.last.column, 2);
      expect(result.complete, isTrue);
    },
  );

  test('explicit delimiter and trailing newline', () {
    final result = LocalDocumentExtractor().extract(
      documentSnapshot(utf8.encode('a;b\n')),
      csvDelimiter: ';',
    );
    expect(result.fragments.map((f) => f.text), ['a', 'b']);
  });

  test('CSV rejects malformed syntax, encoding and limits', () {
    for (final input in ['"open', 'a"b', '"a"x', 'a\u0000']) {
      expect(
        () => LocalDocumentExtractor().extract(
          documentSnapshot(utf8.encode(input)),
        ),
        throwsA(isA<DocumentException>()),
      );
    }
    expect(
      () => LocalDocumentExtractor().extract(documentSnapshot([255])),
      throwsA(isA<DocumentException>()),
    );
    expect(
      () => LocalDocumentExtractor(
        limits: DocumentLimits(columns: 1),
      ).extract(documentSnapshot(utf8.encode('a,b'))),
      throwsA(isA<DocumentException>()),
    );
    expect(
      () => LocalDocumentExtractor(
        limits: DocumentLimits(cellBytes: 2),
      ).extract(documentSnapshot(utf8.encode('рус'))),
      throwsA(isA<DocumentException>()),
    );
  });
}
