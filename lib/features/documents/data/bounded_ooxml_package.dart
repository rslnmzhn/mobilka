import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../domain/document_limits.dart';
import 'strict_deflate.dart';

final class BoundedOoxmlPackage {
  BoundedOoxmlPackage._(this.parts);
  final Map<String, Uint8List> parts;

  factory BoundedOoxmlPackage.read(Uint8List bytes, DocumentLimits limits) {
    try {
      return _read(bytes, limits);
    } on DocumentException {
      rethrow;
    } on Object {
      throw const DocumentException('invalid_document_zip');
    }
  }

  static BoundedOoxmlPackage _read(Uint8List bytes, DocumentLimits limits) {
    if (bytes.length > limits.sourceBytes || bytes.length < 22) _invalid();
    final data = ByteData.sublistView(bytes);
    int u16(int at) => data.getUint16(at, Endian.little);
    int u32(int at) => data.getUint32(at, Endian.little);
    var end = -1;
    for (
      var at = bytes.length - 22;
      at >= 0 && at >= bytes.length - 65557;
      at--
    ) {
      if (u32(at) == 0x06054b50 && at + 22 + u16(at + 20) == bytes.length) {
        if (end != -1) _invalid();
        end = at;
      }
    }
    if (end < 0 || u16(end + 4) != 0 || u16(end + 6) != 0) _invalid();
    final count = u16(end + 10);
    final centralSize = u32(end + 12);
    final centralStart = u32(end + 16);
    if (count == 0 ||
        count == 0xffff ||
        count > limits.zipEntries ||
        u16(end + 8) != count ||
        centralStart + centralSize != end) {
      _invalid();
    }
    final entries = <_ZipPart>[];
    final names = <String>{};
    var at = centralStart;
    var declaredTotal = 0;
    for (var index = 0; index < count; index++) {
      if (at + 46 > end || u32(at) != 0x02014b50) _invalid();
      final flags = u16(at + 8);
      final method = u16(at + 10);
      final crc = u32(at + 16);
      final compressed = u32(at + 20);
      final expanded = u32(at + 24);
      final nameSize = u16(at + 28);
      final extraSize = u16(at + 30);
      final commentSize = u16(at + 32);
      final local = u32(at + 42);
      final next = at + 46 + nameSize + extraSize + commentSize;
      if (next > end ||
          u16(at + 34) != 0 ||
          u16(at + 6) > 20 ||
          (flags & ~0x080e) != 0 ||
          (method != 0 && method != 8) ||
          (method == 0 && (flags & 6) != 0) ||
          ((u32(at + 38) >> 16) & 0xf000) == 0xa000 ||
          compressed == 0xffffffff ||
          expanded == 0xffffffff ||
          local == 0xffffffff) {
        _invalid();
      }
      final rawName = Uint8List.sublistView(bytes, at + 46, at + 46 + nameSize);
      final name = utf8.decode(rawName, allowMalformed: false);
      _validatePartName(name);
      if (!names.add(name.toLowerCase())) {
        throw const DocumentException('duplicate_document_part');
      }
      _validateExtra(data, at + 46 + nameSize, extraSize);
      declaredTotal += expanded;
      if (expanded > limits.memberBytes ||
          declaredTotal > limits.expandedBytes ||
          expanded > compressed * limits.expansionRatio) {
        throw const DocumentException('document_expansion_limit');
      }
      if (local + 30 > centralStart ||
          u32(local) != 0x04034b50 ||
          u16(local + 4) > 20 ||
          u16(local + 6) != flags ||
          u16(local + 8) != method ||
          u16(local + 26) != nameSize) {
        _invalid();
      }
      final localExtra = u16(local + 28);
      final payload = local + 30 + nameSize + localExtra;
      if (payload + compressed > centralStart) _invalid();
      for (var i = 0; i < nameSize; i++) {
        if (bytes[local + 30 + i] != rawName[i]) _invalid();
      }
      _validateExtra(data, local + 30 + nameSize, localExtra);
      final descriptor = (flags & 8) != 0;
      for (final pair in [(14, crc), (18, compressed), (22, expanded)]) {
        final value = u32(local + pair.$1);
        if (value != pair.$2 && !(descriptor && value == 0)) _invalid();
      }
      var localEnd = payload + compressed;
      if (descriptor) {
        if (localEnd + 12 > centralStart) _invalid();
        if (u32(localEnd) == 0x08074b50) localEnd += 4;
        if (localEnd + 12 > centralStart ||
            u32(localEnd) != crc ||
            u32(localEnd + 4) != compressed ||
            u32(localEnd + 8) != expanded) {
          _invalid();
        }
        localEnd += 12;
      }
      entries.add(
        _ZipPart(
          name,
          local,
          localEnd,
          payload,
          compressed,
          expanded,
          method,
          crc,
        ),
      );
      at = next;
    }
    if (at != end) _invalid();
    final ordered = entries.toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    var previousEnd = 0;
    for (final entry in ordered) {
      // Gaps also hide unreferenced local records and self-extracting payloads.
      if (entry.start != previousEnd) _invalid();
      previousEnd = entry.end;
    }
    if (previousEnd != centralStart) _invalid();
    final parts = <String, Uint8List>{};
    var actualTotal = 0;
    for (final entry in entries) {
      final compressed = Uint8List.sublistView(
        bytes,
        entry.payload,
        entry.payload + entry.compressed,
      );
      if (entry.method == 8) {
        validateDocumentDeflate(compressed, entry.expanded);
      } else if (compressed.length != entry.expanded) {
        _invalid();
      }
      final output = _BoundedOutput(entry.expanded);
      if (entry.method == 0) {
        output.writeBytes(compressed);
      } else {
        final input = InputMemoryStream(compressed);
        Inflate.stream(input, output: output);
        if (!input.isEOS) _invalid();
      }
      final content = output.getBytes();
      actualTotal += content.length;
      if (content.length != entry.expanded || getCrc32(content) != entry.crc) {
        _invalid();
      }
      if (actualTotal > limits.expandedBytes) {
        throw const DocumentException('document_expansion_limit');
      }
      final lower = entry.name.toLowerCase();
      if (lower.endsWith('.bin') ||
          lower.contains('/embeddings/') ||
          lower.contains('/activex/') ||
          lower.contains('vbaproject')) {
        throw const DocumentException('unsupported_document_active_content');
      }
      if (lower.endsWith('.xml') || lower.endsWith('.rels')) {
        parts[entry.name] = content.asUnmodifiableView();
      }
    }
    return BoundedOoxmlPackage._(Map.unmodifiable(parts));
  }

  Uint8List require(String name) =>
      parts[name] ?? (throw const DocumentException('missing_document_part'));

  static void _validatePartName(String name) {
    if (name.isEmpty ||
        name.length > 1024 ||
        name.startsWith('/') ||
        name.contains('\\') ||
        name.contains(':') ||
        name.contains('%') ||
        name.contains('?') ||
        name.contains('#') ||
        name.runes.any((r) => r < 32 || r == 127)) {
      _invalid();
    }
    final segments = name.endsWith('/')
        ? name.substring(0, name.length - 1).split('/')
        : name.split('/');
    if (segments.any(
      (s) =>
          s.isEmpty ||
          s == '.' ||
          s == '..' ||
          s.endsWith(' ') ||
          s.endsWith('.'),
    )) {
      _invalid();
    }
  }

  static void _validateExtra(ByteData data, int start, int length) {
    final end = start + length;
    while (start < end) {
      if (start + 4 > end) _invalid();
      final tag = data.getUint16(start, Endian.little);
      final size = data.getUint16(start + 2, Endian.little);
      if (tag == 1 || tag == 0x7075 || tag == 0x9901) _invalid();
      start += 4 + size;
      if (start > end) _invalid();
    }
  }

  static Never _invalid() =>
      throw const DocumentException('invalid_document_zip');
}

final class _ZipPart {
  const _ZipPart(
    this.name,
    this.start,
    this.end,
    this.payload,
    this.compressed,
    this.expanded,
    this.method,
    this.crc,
  );
  final String name;
  final int start;
  final int end;
  final int payload;
  final int compressed;
  final int expanded;
  final int method;
  final int crc;
}

final class _BoundedOutput extends OutputStream {
  _BoundedOutput(int maximum)
    : _bytes = Uint8List(maximum),
      super(byteOrder: ByteOrder.littleEndian);
  final Uint8List _bytes;
  int _length = 0;
  @override
  int get length => _length;

  void _reserve(int count) {
    if (count < 0 || count > _bytes.length - _length) {
      throw const DocumentException('document_expansion_limit');
    }
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    _bytes[_length++] = value;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    _reserve(count);
    if (count > bytes.length) {
      throw const DocumentException('invalid_document_zip');
    }
    _bytes.setRange(_length, _length + count, bytes);
    _length += count;
  }

  @override
  void writeStream(InputStream stream) {
    _reserve(stream.length);
    writeBytes(stream.toUint8List());
  }

  @override
  void writeBackReference(int distance, int count) {
    _reserve(count);
    if (distance <= 0 || distance > _length) {
      throw const DocumentException('invalid_document_zip');
    }
    for (var i = 0; i < count; i++) {
      _bytes[_length] = _bytes[_length - distance];
      _length++;
    }
  }

  @override
  Uint8List subset(int start, [int? end]) {
    final from = start < 0 ? _length + start : start;
    final to = end == null ? _length : (end < 0 ? _length + end : end);
    if (from < 0 || to < from || to > _length) {
      throw const DocumentException('invalid_document_zip');
    }
    return Uint8List.sublistView(_bytes, from, to);
  }

  @override
  void clear() => _length = 0;
  @override
  void flush() {}
}
