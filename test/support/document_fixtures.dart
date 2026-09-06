import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:mobilka/core/workspace/workspace_binding.dart';
import 'package:mobilka/features/documents/domain/document_snapshot.dart';

DocumentSnapshot documentSnapshot(
  List<int> bytes, {
  String path = 'input.csv',
}) => DocumentSnapshot(
  documentId: 'document',
  conversationId: 'conversation',
  requestId: 'request',
  sessionKey: 'session',
  binding: const WorkspaceBindingSnapshot(
    isContentUri: false,
    value: 'private-root',
    identity: 'grant',
    rootIdentity: 'root-id',
  ),
  sourcePath: path,
  sourceIdentity: 'file-id',
  bytes: bytes,
);

Uint8List documentZip(
  List<(String, List<int>)> entries, {
  bool deflate = false,
  bool descriptor = false,
  bool signedDescriptor = true,
  List<int> Function(List<int>)? compressedOverride,
}) {
  final body = BytesBuilder();
  final directory = BytesBuilder();
  for (final entry in entries) {
    final name = utf8.encode(entry.$1);
    final bytes = entry.$2;
    final compressed = compressedOverride?.call(bytes) ??
        (deflate ? Deflate(bytes).getBytes() : bytes);
    final crc = getCrc32(bytes);
    final offset = body.length;
    final local = ByteData(30);
    local.setUint32(0, 0x04034b50, Endian.little);
    local.setUint16(4, 20, Endian.little);
    local.setUint16(6, descriptor ? 0x808 : 0x800, Endian.little);
    local.setUint16(8, deflate ? 8 : 0, Endian.little);
    if (!descriptor) {
      local.setUint32(14, crc, Endian.little);
      local.setUint32(18, compressed.length, Endian.little);
      local.setUint32(22, bytes.length, Endian.little);
    }
    local.setUint16(26, name.length, Endian.little);
    body.add(local.buffer.asUint8List());
    body.add(name);
    body.add(compressed);
    if (descriptor) {
      final record = ByteData(signedDescriptor ? 16 : 12);
      final start = signedDescriptor ? 4 : 0;
      if (signedDescriptor) {
        record.setUint32(0, 0x08074b50, Endian.little);
      }
      record.setUint32(start, crc, Endian.little);
      record.setUint32(start + 4, compressed.length, Endian.little);
      record.setUint32(start + 8, bytes.length, Endian.little);
      body.add(record.buffer.asUint8List());
    }
    final central = ByteData(46);
    central.setUint32(0, 0x02014b50, Endian.little);
    central.setUint16(4, 20, Endian.little);
    central.setUint16(6, 20, Endian.little);
    central.setUint16(8, descriptor ? 0x808 : 0x800, Endian.little);
    central.setUint16(10, deflate ? 8 : 0, Endian.little);
    central.setUint32(16, crc, Endian.little);
    central.setUint32(20, compressed.length, Endian.little);
    central.setUint32(24, bytes.length, Endian.little);
    central.setUint16(28, name.length, Endian.little);
    central.setUint32(42, offset, Endian.little);
    directory.add(central.buffer.asUint8List());
    directory.add(name);
  }
  final end = ByteData(22);
  end.setUint32(0, 0x06054b50, Endian.little);
  end.setUint16(8, entries.length, Endian.little);
  end.setUint16(10, entries.length, Endian.little);
  end.setUint32(12, directory.length, Endian.little);
  end.setUint32(16, body.length, Endian.little);
  body.add(directory.takeBytes());
  body.add(end.buffer.asUint8List());
  return body.takeBytes();
}

const wordNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const sheetNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const relNs =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const packageRelNs =
    'http://schemas.openxmlformats.org/package/2006/relationships';

List<(String, List<int>)> officeParts({
  required bool spreadsheet,
  required String body,
  Map<String, String> extra = const {},
}) {
  final main = spreadsheet ? 'xl/workbook.xml' : 'word/document.xml';
  final type = spreadsheet
      ? 'spreadsheetml.sheet'
      : 'wordprocessingml.document';
  return [
    (
      '[Content_Types].xml',
      utf8.encode(
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Override PartName="/$main" ContentType="application/vnd.openxmlformats-officedocument.$type.main+xml"/>'
        '</Types>',
      ),
    ),
    (
      '_rels/.rels',
      utf8.encode(
        '<Relationships xmlns="$packageRelNs">'
        '<Relationship Id="main" Type="$relNs/officeDocument" Target="$main"/>'
        '</Relationships>',
      ),
    ),
    (main, utf8.encode(body)),
    for (final entry in extra.entries) (entry.key, utf8.encode(entry.value)),
  ];
}

Uint8List simpleDocx(String body) => documentZip(
  officeParts(
    spreadsheet: false,
    body: '<w:document xmlns:w="$wordNs"><w:body>$body</w:body></w:document>',
  ),
);

Uint8List simpleXlsx(
  String cells, {
  Map<String, String> extra = const {},
}) => documentZip(
  officeParts(
    spreadsheet: true,
    body:
        '<workbook xmlns="$sheetNs" xmlns:r="$relNs"><sheets>'
        '<sheet name="Лист" sheetId="1" r:id="sheet" state="hidden"/>'
        '</sheets></workbook>',
    extra: {
      'xl/_rels/workbook.xml.rels':
          '<Relationships xmlns="$packageRelNs">'
          '<Relationship Id="sheet" Type="$relNs/worksheet" Target="worksheets/sheet1.xml"/>'
          '</Relationships>',
      'xl/worksheets/sheet1.xml':
          '<worksheet xmlns="$sheetNs">'
          '<dimension ref="A1:XFD1048576"/><sheetData><row r="1">$cells</row>'
          '</sheetData></worksheet>',
      ...extra,
    },
  ),
);
