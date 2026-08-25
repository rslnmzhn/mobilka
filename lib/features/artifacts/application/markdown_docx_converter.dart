import 'package:archive/archive.dart';

/// Converts Markdown into a minimal, Word-compatible `.docx` (OOXML) file.
///
/// Supported blocks per guide.md §6.1 (basic documents): headings (#..####),
/// bullet/ordered lists, fenced code blocks, blockquotes, horizontal rules,
/// and plain paragraphs. Inline formatting: **bold**, *italic*, `code`.
/// Complex layouts are out of scope; a preloaded-template workflow can wrap
/// this converter later.
class MarkdownDocxConverter {
  const MarkdownDocxConverter();

  static const _contentTypes =
      '<?xml version="1.0" encoding="UTF-8" '
      'standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/'
      'content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-'
      'package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.'
      'openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '<Override PartName="/word/styles.xml" ContentType="application/vnd.'
      'openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
      '<Override PartName="/docProps/core.xml" ContentType="application/vnd.'
      'openxmlformats-package.core-properties+xml"/>'
      '<Override PartName="/docProps/app.xml" ContentType="application/vnd.'
      'openxmlformats-officedocument.extended-properties+xml"/>'
      '</Types>';

  static const _rootRels =
      '<?xml version="1.0" encoding="UTF-8" '
      'standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/'
      'relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/'
      'officeDocument/2006/relationships/officeDocument" '
      'Target="word/document.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/'
      'package/2006/relationships/metadata/core-properties" '
      'Target="docProps/core.xml"/>'
      '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/'
      'officeDocument/2006/relationships/extended-properties" '
      'Target="docProps/app.xml"/>'
      '</Relationships>';

  static const _documentRels =
      '<?xml version="1.0" encoding="UTF-8" '
      'standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/'
      'relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/'
      'officeDocument/2006/relationships/styles" Target="styles.xml"/>'
      '</Relationships>';

  static String _coreXml({required String title, required DateTime created}) =>
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/'
      'package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/'
      'elements/1.1/">'
      '<dc:title>${_escapeXml(title)}</dc:title>'
      '<dc:creator>mobilka</dc:creator>'
      '<cp:lastModifiedBy>mobilka</cp:lastModifiedBy>'
      '<dcterms:created xmlns:dcterms="http://purl.org/dc/terms/" '
      'xsi:type="dcterms:W3CDTF" xmlns:xsi="http://www.w3.org/2001/'
      'XMLSchema-instance">${created.toUtc().toIso8601String()}</dcterms:created>'
      '</cp:coreProperties>';

  static const _appXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/'
      '2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/'
      'officeDocument/2006/docPropsVTypes">'
      '<Application>mobilka</Application>'
      '</Properties>';

  static String _escapeXml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static const _styles =
      '<?xml version="1.0" encoding="UTF-8" '
      'standalone="yes"?>'
      '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/'
      '2006/main">'
      '<w:style w:type="paragraph" w:styleId="Heading1">'
      '<w:name w:val="heading 1"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr>'
      '<w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Heading2">'
      '<w:name w:val="heading 2"/><w:pPr><w:outlineLvl w:val="1"/></w:pPr>'
      '<w:rPr><w:b/><w:sz w:val="30"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Heading3">'
      '<w:name w:val="heading 3"/><w:pPr><w:outlineLvl w:val="2"/></w:pPr>'
      '<w:rPr><w:b/><w:sz w:val="26"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="CodeBlock">'
      '<w:name w:val="Code Block"/><w:pPr><w:ind w:left="360"/></w:pPr>'
      '<w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/>'
      '<w:sz w:val="20"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="QuoteBlock">'
      '<w:name w:val="Quote Block"/><w:pPr><w:ind w:left="720"/></w:pPr>'
      '<w:rPr><w:i/><w:color w:val="555555"/></w:rPr></w:style>'
      '</w:styles>';

  /// Generates a complete `.docx` archive for [title] and [markdown].
  List<int> generate({required String title, required String markdown}) {
    final body = StringBuffer();
    body.write(_paragraph(style: 'Heading1', runs: _runs(title)));
    var inCodeFence = false;

    for (final rawLine in markdown.split('\n')) {
      final line = rawLine.replaceAll('\r', '');
      if (line.trimLeft().startsWith('```')) {
        inCodeFence = !inCodeFence;
        continue;
      }
      if (inCodeFence) {
        body.write(_verbatimParagraph(style: 'CodeBlock', text: line));
        continue;
      }
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final heading = RegExp(r'^(#{1,4})\s+(.*)$').firstMatch(trimmed);
      if (heading != null) {
        final marker = heading.group(1);
        final level = (marker?.length ?? 1).clamp(1, 3);
        body.write(
          _paragraph(style: 'Heading$level', runs: _runs(heading.group(2)!)),
        );
        continue;
      }
      if (RegExp(r'^(-{3,}|\*{3,})$').hasMatch(trimmed)) {
        body.write(_horizontalRule());
        continue;
      }
      if (trimmed.startsWith('&gt;') || trimmed.startsWith('>')) {
        final text = trimmed.startsWith('&gt;')
            ? trimmed.substring(4).trim()
            : trimmed.substring(1).trim();
        body.write(_paragraph(style: 'QuoteBlock', runs: _runs(text)));
        continue;
      }
      final bullet = RegExp(r'^[-*+]\s+(.*)$').firstMatch(trimmed);
      if (bullet != null) {
        body.write(_paragraph(runs: _runs('• ${bullet.group(1)!}')));
        continue;
      }
      final ordered = RegExp(r'^(\d+)[.)]\s+(.*)$').firstMatch(trimmed);
      if (ordered != null) {
        body.write(
          _paragraph(runs: _runs('${ordered.group(1)}. ${ordered.group(2)!}')),
        );
        continue;
      }
      body.write(_paragraph(runs: _runs(trimmed)));
    }

    final document =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/'
        'wordprocessingml/2006/main"><w:body>$body'
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr></w:body>'
        '</w:document>';

    final archive = Archive()
      ..addFile(ArchiveFile.string('[Content_Types].xml', _contentTypes))
      ..addFile(ArchiveFile.string('_rels/.rels', _rootRels))
      ..addFile(
        ArchiveFile.string('word/_rels/document.xml.rels', _documentRels),
      )
      ..addFile(ArchiveFile.string('word/styles.xml', _styles))
      ..addFile(
        ArchiveFile.string(
          'docProps/core.xml',
          _coreXml(title: title, created: DateTime.now()),
        ),
      )
      ..addFile(ArchiveFile.string('docProps/app.xml', _appXml))
      ..addFile(ArchiveFile.string('word/document.xml', document));
    return ZipEncoder().encode(archive);
  }

  String _paragraph({String? style, required String runs}) =>
      '<w:p>${style == null ? '' : '<w:pPr><w:pStyle w:val="$style"/></w:pPr>'}'
      '$runs</w:p>';

  String _verbatimParagraph({required String style, required String text}) =>
      '<w:p><w:pPr><w:pStyle w:val="$style"/></w:pPr>'
      '<w:r><w:t xml:space="preserve">${_escape(text)}</w:t></w:r></w:p>';

  String _horizontalRule() =>
      '<w:p><w:pPr>'
      '<w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1"/></w:pBdr>'
      '</w:pPr></w:p>';

  /// Splits inline Markdown into runs, preserving bold/italic/code marks.
  String _runs(String text) {
    final pattern = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*|`(.+?)`');
    final buffer = StringBuffer();
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > cursor) {
        buffer.write(_run(text.substring(cursor, match.start)));
      }
      if (match.group(1) != null) {
        buffer.write(_run(match.group(1)!, bold: true));
      } else if (match.group(2) != null) {
        buffer.write(_run(match.group(2)!, italic: true));
      } else {
        buffer.write(_run(match.group(3)!, code: true));
      }
      cursor = match.end;
    }
    if (cursor < text.length) {
      buffer.write(_run(text.substring(cursor)));
    }
    return buffer.toString();
  }

  String _run(
    String text, {
    bool bold = false,
    bool italic = false,
    bool code = false,
  }) {
    if (text.isEmpty) return '';
    final properties = StringBuffer('<w:rPr>');
    if (code) {
      properties.write('<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/>');
    }
    if (bold) properties.write('<w:b/>');
    if (italic) properties.write('<w:i/>');
    properties.write('</w:rPr>');
    return '<w:r>$properties'
        '<w:t xml:space="preserve">${_escape(text)}</w:t></w:r>';
  }

  String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
