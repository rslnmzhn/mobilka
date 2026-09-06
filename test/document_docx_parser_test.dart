import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/artifacts/application/markdown_docx_converter.dart';
import 'package:mobilka/features/documents/application/local_document_extractor.dart';

import 'support/document_fixtures.dart';

void main() {
  test('existing artifact converter output remains readable', () {
    final bytes = const MarkdownDocxConverter().generate(
      title: 'Report',
      markdown: 'Hello **world**\n\nПривет',
    );
    final result = LocalDocumentExtractor().extract(
      documentSnapshot(bytes, path: 'report.docx'),
    );
    expect(result.fragments.map((f) => f.text).join('\n'), contains('Привет'));
  });

  test('DOCX main body and table provenance are ordered', () {
    final result = LocalDocumentExtractor().extract(
      documentSnapshot(
        simpleDocx(
          '<w:p><w:r><w:t>Привет &amp; hello</w:t><w:tab/><w:t>x</w:t></w:r>'
          '<w:del><w:r><w:t>deleted</w:t></w:r></w:del></w:p>'
          '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>cell</w:t></w:r></w:p>'
          '</w:tc></w:tr></w:tbl>',
        ),
        path: 'input.docx',
      ),
    );
    expect(result.fragments.map((f) => f.text), ['Привет & hello\tx', 'cell']);
    expect(result.fragments.last.table, 1);
    expect(result.fragments.last.row, 1);
    expect(result.fragments.last.column, 1);
    expect(result.warnings, contains('docx_main_body_only'));
  });

  test('fields are inert and unsupported images are reported', () {
    final result = LocalDocumentExtractor().extract(
      documentSnapshot(
        simpleDocx(
          '<w:p><w:r><w:instrText>DDE dangerous</w:instrText><w:t>cached</w:t>'
          '<w:drawing/></w:r></w:p>',
        ),
        path: 'input.docx',
      ),
    );
    expect(result.fragments.single.text, 'cached');
    expect(result.warnings, contains('unsupported_docx_content_skipped'));
  });
}
