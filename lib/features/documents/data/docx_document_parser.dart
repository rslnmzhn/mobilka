import '../domain/document_extraction.dart';
import '../domain/document_limits.dart';
import 'bounded_document_xml.dart';

void parseDocxDocument(DocumentPackageXml package, DocumentOutput output) {
  final part = package.mainPart(
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml',
    output.warnings,
  );
  final root = package.require(part);
  if (!root.isName(wordNamespace, 'document')) {
    throw const DocumentException('invalid_docx');
  }
  final bodies = root.children
      .where((n) => n.isName(wordNamespace, 'body'))
      .toList();
  if (bodies.length != 1) throw const DocumentException('invalid_docx');
  package.relationships(part, output.warnings);
  var paragraph = 0;
  var table = 0;

  String paragraphText(DocumentXmlNode node) {
    final text = StringBuffer();
    void append(String value) {
      if (text.length + value.length > output.limits.cellBytes) {
        throw const DocumentException('document_output_limit');
      }
      text.write(value);
    }

    void visit(DocumentXmlNode child) {
      if (child.namespace != wordNamespace) {
        output.warnings.add('unsupported_docx_content_skipped');
        return;
      }
      switch (child.name) {
        case 'del':
        case 'instrText':
        case 'delText':
          output.warnings.add('docx_revisions_or_fields_skipped');
          return;
        case 'drawing':
        case 'pict':
        case 'object':
        case 'altChunk':
        case 'footnoteReference':
        case 'endnoteReference':
          output.warnings.add('unsupported_docx_content_skipped');
          return;
        case 't':
          append(child.text);
          return;
        case 'tab':
          append('\t');
          return;
        case 'br':
        case 'cr':
          append('\n');
          return;
        case 'fldChar':
        case 'fldSimple':
          output.warnings.add('docx_cached_fields');
      }
      for (final nested in child.children) {
        visit(nested);
      }
    }

    visit(node);
    return text.toString();
  }

  void emitParagraph(
    DocumentXmlNode node, {
    int? tableId,
    int? row,
    int? column,
  }) {
    output.add(
      DocumentFragment(
        text: paragraphText(node),
        part: part,
        paragraph: ++paragraph,
        table: tableId,
        row: row,
        column: column,
      ),
    );
  }

  for (final block in bodies.single.children) {
    if (block.isName(wordNamespace, 'p')) {
      emitParagraph(block);
    } else if (block.isName(wordNamespace, 'tbl')) {
      final tableId = ++table;
      var row = 0;
      for (final tr in block.children.where(
        (n) => n.isName(wordNamespace, 'tr'),
      )) {
        if (++row > output.limits.rows) {
          throw const DocumentException('document_table_limit');
        }
        var column = 0;
        for (final cell in tr.children.where(
          (n) => n.isName(wordNamespace, 'tc'),
        )) {
          if (++column > output.limits.columns) {
            throw const DocumentException('document_table_limit');
          }
          for (final child in cell.children) {
            if (child.isName(wordNamespace, 'p')) {
              emitParagraph(child, tableId: tableId, row: row, column: column);
            } else if (!child.isName(wordNamespace, 'tcPr')) {
              output.warnings.add('unsupported_docx_content_skipped');
            }
          }
        }
      }
    } else if (!block.isName(wordNamespace, 'sectPr')) {
      output.warnings.add('unsupported_docx_content_skipped');
    }
  }
  // Main-body text cannot represent pagination, headers, notes, or drawings.
  output.warnings.add('docx_main_body_only');
}
