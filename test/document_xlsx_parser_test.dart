import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/documents/application/local_document_extractor.dart';
import 'package:mobilka/features/documents/domain/document_limits.dart';

import 'support/document_fixtures.dart';

void main() {
  test('XLSX preserves sparse cells, inline strings and inert caches', () {
    final result = LocalDocumentExtractor().extract(
      documentSnapshot(
        simpleXlsx(
          '<c r="A1" t="inlineStr"><is><t>Привет</t></is></c>'
          '<c r="C1"><f>SUM(A1:B1)</f><v>12</v></c>'
          '<c r="D1"><f>WEBSERVICE("https://example.com")</f></c>',
        ),
        path: 'input.xlsx',
      ),
    );
    expect(result.fragments.map((f) => f.text), ['Привет', '12', '']);
    expect(result.fragments[1].column, 3);
    expect(result.fragments[1].formula, 'SUM(A1:B1)');
    expect(result.fragments.first.sheetVisibility, 'hidden');
    expect(result.warnings, contains('xlsx_formula_without_cache'));
  });

  test(
    'XLSX rejects duplicate cells, out-of-range cells and shared indexes',
    () {
      for (final cells in [
        '<c r="A1"/><c r="A1"/>',
        '<c r="XFD1"/>',
        '<c r="A1" t="s"><v>0</v></c>',
        '<c r="A2"/>',
      ]) {
        expect(
          () => LocalDocumentExtractor().extract(
            documentSnapshot(simpleXlsx(cells), path: 'input.xlsx'),
          ),
          throwsA(isA<DocumentException>()),
        );
      }
    },
  );
}
