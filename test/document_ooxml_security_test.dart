import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/documents/application/local_document_extractor.dart';
import 'package:mobilka/features/documents/data/bounded_document_xml.dart';
import 'package:mobilka/features/documents/data/bounded_ooxml_package.dart';
import 'package:mobilka/features/documents/domain/document_limits.dart';

import 'support/document_fixtures.dart';

void main() {
  final rejected = throwsA(isA<DocumentException>());

  test('descriptor signature CRC is valid in either boundary-sized layout', () {
    final content = Uint8List(4);
    final zeroCrc = getCrc32(content);
    final basis = List<int>.filled(32, 0);
    final masks = List<int>.filled(32, 0);
    // Solve the CRC's affine bit mapping rather than overriding ZIP metadata.
    for (var bit = 0; bit < 32; bit++) {
      final probe = Uint8List(4)..[bit ~/ 8] = 1 << (bit % 8);
      var value = getCrc32(probe) ^ zeroCrc;
      var mask = 1 << bit;
      for (var pivot = 31; pivot >= 0; pivot--) {
        if ((value & (1 << pivot)) == 0) continue;
        if (basis[pivot] == 0) {
          basis[pivot] = value;
          masks[pivot] = mask;
          break;
        }
        value ^= basis[pivot];
        mask ^= masks[pivot];
      }
    }
    var remaining = 0x08074b50 ^ zeroCrc;
    var solution = 0;
    for (var pivot = 31; pivot >= 0; pivot--) {
      if ((remaining & (1 << pivot)) == 0) continue;
      expect(basis[pivot], isNot(0));
      remaining ^= basis[pivot];
      solution ^= masks[pivot];
    }
    ByteData.sublistView(content).setUint32(0, solution, Endian.little);
    expect(remaining, 0);
    expect(getCrc32(content), 0x08074b50);
    for (final signed in [false, true]) {
      for (final deflate in [false, true]) {
        for (final followed in [false, true]) {
          final original = documentZip(
            [
              ('collision.xml', content),
              if (followed) ('next.xml', utf8.encode('<next/>')),
            ],
            deflate: deflate,
            descriptor: true,
            signedDescriptor: signed,
          );
          expect(
            BoundedOoxmlPackage.read(
              original,
              DocumentLimits(),
            ).require('collision.xml'),
            orderedEquals(content),
          );
          final data = ByteData.sublistView(original);
          final central = data.getUint32(original.length - 6, Endian.little);
          final record =
              30 +
              utf8.encode('collision.xml').length +
              data.getUint32(central + 20, Endian.little);
          for (final field in [0, 4, 8]) {
            final damaged = Uint8List.fromList(original);
            damaged[record + (signed ? 4 : 0) + field] ^= 1;
            expect(
              () => BoundedOoxmlPackage.read(damaged, DocumentLimits()),
              rejected,
            );
          }
          if (signed) {
            final damaged = Uint8List.fromList(original)..[record] ^= 1;
            expect(
              () => BoundedOoxmlPackage.read(damaged, DocumentLimits()),
              rejected,
            );
          }
          if (!followed) {
            for (final padding in [
              <int>[],
              [0, 0, 0, 0],
            ]) {
              final malformed = Uint8List.fromList([
                ...original.sublist(0, central - (padding.isEmpty ? 1 : 0)),
                ...padding,
                ...original.sublist(central),
              ]);
              ByteData.sublistView(malformed).setUint32(
                malformed.length - 6,
                central + (padding.isEmpty ? -1 : padding.length),
                Endian.little,
              );
              expect(
                () => BoundedOoxmlPackage.read(malformed, DocumentLimits()),
                rejected,
              );
            }
          }
        }
      }
    }
  });

  test(
    'signed and unsigned descriptors round trip and reject damaged fields',
    () {
      for (final signed in [false, true]) {
        final original = documentZip(
          [('a.xml', utf8.encode('<a/>'))],
          deflate: true,
          descriptor: true,
          signedDescriptor: signed,
        );
        expect(
          utf8.decode(
            BoundedOoxmlPackage.read(
              original,
              DocumentLimits(),
            ).require('a.xml'),
          ),
          '<a/>',
        );
        final originalData = ByteData.sublistView(original);
        final central = originalData.getUint32(
          original.length - 6,
          Endian.little,
        );
        final start = central - (signed ? 16 : 12);
        for (final field in [0, 4, 8]) {
          final damaged = Uint8List.fromList(original);
          damaged[start + (signed ? 4 : 0) + field] ^= 1;
          expect(
            () => BoundedOoxmlPackage.read(damaged, DocumentLimits()),
            rejected,
          );
        }
        // Remove one descriptor byte while keeping the central directory and
        // EOCD internally consistent, so this reaches descriptor validation.
        final truncated = Uint8List.fromList([
          ...original.sublist(0, central - 1),
          ...original.sublist(central),
        ]);
        ByteData.sublistView(
          truncated,
        ).setUint32(truncated.length - 6, central - 1, Endian.little);
        expect(
          () => BoundedOoxmlPackage.read(truncated, DocumentLimits()),
          rejected,
        );
      }
    },
  );

  test('valid ZIP envelope reaches strict DEFLATE gate before CRC checks', () {
    for (final compressed in [
      [7],
      [2, 0],
      [3, 0, 0],
      [3],
    ]) {
      final zip = documentZip(
        [('a.xml', <int>[])],
        deflate: true,
        compressedOverride: (_) => compressed,
      );
      expect(
        () => BoundedOoxmlPackage.read(zip, DocumentLimits()),
        throwsA(
          isA<DocumentException>().having(
            (e) => e.code,
            'code',
            'invalid_document_deflate',
          ),
        ),
      );
    }
    final bomb = documentZip(
      [('a.xml', <int>[])],
      deflate: true,
      compressedOverride: (_) => [1, 1, 0, 254, 255, 65],
    );
    expect(
      () => BoundedOoxmlPackage.read(bomb, DocumentLimits()),
      throwsA(
        isA<DocumentException>().having(
          (e) => e.code,
          'code',
          'document_expansion_limit',
        ),
      ),
    );
  });

  test('central and local compressed and expanded sizes must agree', () {
    for (final offset in [18, 22]) {
      final zip = documentZip([('a.xml', utf8.encode('<a/>'))], deflate: true);
      zip[offset] ^= 1;
      expect(() => BoundedOoxmlPackage.read(zip, DocumentLimits()), rejected);
    }
  });

  test('real deflated DOCX and XLSX packages extract locally', () {
    final docx = documentZip(
      officeParts(
        spreadsheet: false,
        body:
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<!-- <!DOCTYPE ignored> <!ENTITY ignored> -->'
            '<w:document xmlns:w="$wordNs"><w:body><w:p><w:r>'
            '<w:t>Привет <![CDATA[<!DOCTYPE literal> <!ENTITY literal>]]>'
            '<!-- <!DOCTYPE ignored> <!ENTITY ignored> --> document</w:t>'
            '</w:r></w:p></w:body></w:document>',
      ),
      deflate: true,
      descriptor: true,
    );
    final workbook = officeParts(
      spreadsheet: true,
      body:
          '<workbook xmlns="$sheetNs" xmlns:r="$relNs"><sheets>'
          '<sheet name="Лист" sheetId="1" r:id="sheet"/></sheets></workbook>',
      extra: {
        'xl/_rels/workbook.xml.rels':
            '<Relationships xmlns="$packageRelNs">'
            '<Relationship Id="sheet" Type="$relNs/worksheet" Target="worksheets/sheet1.xml"/>'
            '<Relationship Id="strings" Type="$relNs/sharedStrings" Target="sharedStrings.xml"/>'
            '</Relationships>',
        'xl/sharedStrings.xml':
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<!-- <!DOCTYPE ignored> <!ENTITY ignored> -->'
            '<sst xmlns="$sheetNs"><si><r><t>Привет '
            '<![CDATA[<!DOCTYPE literal> <!ENTITY literal>]]>'
            '<!-- <!DOCTYPE ignored> <!ENTITY ignored> --></t></r>'
            '<r><t> sheet</t></r></si></sst>',
        'xl/worksheets/sheet1.xml':
            '<worksheet xmlns="$sheetNs"><sheetData>'
            '<row r="1"><c r="A1" t="s"><v>0</v></c></row></sheetData></worksheet>',
      },
    );
    final xlsx = documentZip(
      workbook,
      deflate: true,
      descriptor: true,
      signedDescriptor: false,
    );
    final extractor = LocalDocumentExtractor();
    expect(
      extractor
          .extract(documentSnapshot(docx, path: 'input.docx'))
          .fragments
          .single
          .text,
      'Привет <!DOCTYPE literal> <!ENTITY literal> document',
    );
    expect(
      extractor
          .extract(documentSnapshot(xlsx, path: 'input.xlsx'))
          .fragments
          .single
          .text,
      'Привет <!DOCTYPE literal> <!ENTITY literal> sheet',
    );
  });

  test('stored and deflated members round trip with CRC verification', () {
    for (final deflate in [false, true]) {
      final bytes = documentZip([
        ('a.xml', utf8.encode('<a>Привет</a>')),
      ], deflate: deflate);
      final package = BoundedOoxmlPackage.read(bytes, DocumentLimits());
      expect(utf8.decode(package.require('a.xml')), '<a>Привет</a>');
    }
  });

  test('duplicate central records and path aliases are rejected', () {
    for (final names in [
      ['a.xml', 'a.xml'],
      ['a.xml', 'A.xml'],
      ['../a.xml'],
      ['/a.xml'],
      ['a/./b.xml'],
      ['a%2fb.xml'],
      ['a\\b.xml'],
    ]) {
      expect(
        () => BoundedOoxmlPackage.read(
          documentZip([for (final name in names) (name, utf8.encode('<a/>'))]),
          DocumentLimits(),
        ),
        rejected,
      );
    }
  });

  test(
    'CRC, local metadata, encryption, symlink and overlapping records fail closed',
    () {
      final original = documentZip([('a.xml', utf8.encode('<a/>'))]);
      for (final mutate in <void Function(ByteData, int)>[
        (data, central) => data.setUint8(35, 0),
        (data, central) => data.setUint16(8, 99, Endian.little),
        (data, central) => data.setUint16(central + 8, 1, Endian.little),
        (data, central) =>
            data.setUint32(central + 38, 0xa0000000, Endian.little),
        (data, central) => data.setUint32(central + 42, 1, Endian.little),
        (data, central) =>
            data.setUint32(central + 24, 0xffffffff, Endian.little),
      ]) {
        final bytes = Uint8List.fromList(original);
        final data = ByteData.sublistView(bytes);
        final central = data.getUint32(bytes.length - 6, Endian.little);
        mutate(data, central);
        expect(
          () => BoundedOoxmlPackage.read(bytes, DocumentLimits()),
          rejected,
        );
      }
    },
  );

  test('actual expansion cannot exceed a lying declared length', () {
    final bytes = documentZip([
      ('a.xml', utf8.encode('a' * 1000)),
    ], deflate: true);
    final data = ByteData.sublistView(bytes);
    final central = data.getUint32(bytes.length - 6, Endian.little);
    data.setUint32(22, 1, Endian.little);
    data.setUint32(central + 24, 1, Endian.little);
    expect(() => BoundedOoxmlPackage.read(bytes, DocumentLimits()), rejected);
  });

  test('aggregate expansion and entry limits apply before extraction', () {
    final bytes = documentZip([
      ('a.xml', utf8.encode('1234')),
      ('b.xml', utf8.encode('5678')),
    ]);
    expect(
      () => BoundedOoxmlPackage.read(bytes, DocumentLimits(expandedBytes: 7)),
      rejected,
    );
    expect(
      () => BoundedOoxmlPackage.read(bytes, DocumentLimits(zipEntries: 1)),
      rejected,
    );
  });

  test(
    'DTD, processing instructions, invalid namespaces and nesting are rejected',
    () {
      for (final xml in [
        '<!DOCTYPE a [<!ENTITY x SYSTEM "file:///secret">]><a>&x;</a>',
        '<!-- <!DOCTYPE inert> --><!DOCTYPE a><a/>',
        '<!DOCTYPE a [<!ENTITY x "expanded">]><a>&x;</a>',
        '<!ENTITY x "expanded"><a/>',
        '<a><![CDATA[<!DOCTYPE inert>]]><?fetch blocked?></a>',
        '<?fetch https://example.com?><a/>',
        '<p:a/>',
        '<a><b></a>',
        '<a>&unknown;</a>',
        '<a x="1" x="2"/>',
      ]) {
        expect(
          () => BoundedDocumentXml(DocumentLimits()).parse(utf8.encode(xml)),
          rejected,
        );
      }
      expect(
        () => BoundedDocumentXml(
          DocumentLimits(xmlDepth: 1),
        ).parse(utf8.encode('<a><b/></a>')),
        rejected,
      );
      expect(
        () => BoundedDocumentXml(
          DocumentLimits(xmlEvents: 1),
        ).parse(utf8.encode('<a>text</a>')),
        rejected,
      );
    },
  );

  test('external relationships are inert and traversal and macros rejected', () {
    final entries = officeParts(
      spreadsheet: false,
      body: '<w:document xmlns:w="$wordNs"/>',
      extra: {
        'word/_rels/document.xml.rels':
            '<Relationships xmlns="$packageRelNs">'
            '<Relationship Id="x" Type="$relNs/hyperlink" Target="https://example.com" TargetMode="External"/>'
            '</Relationships>',
      },
    );
    final package = DocumentPackageXml(
      BoundedOoxmlPackage.read(documentZip(entries), DocumentLimits()),
      DocumentLimits(),
    );
    final warnings = <String>{};
    expect(
      package.relationships('word/document.xml', warnings)['x']!.target,
      isNull,
    );
    expect(warnings, contains('external_resources_skipped'));
    expect(
      () => BoundedOoxmlPackage.read(
        documentZip([
          ('word/vbaProject.bin', [1, 2, 3]),
        ]),
        DocumentLimits(),
      ),
      rejected,
    );
  });
}
