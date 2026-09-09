import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/documents/data/strict_deflate.dart';
import 'package:mobilka/features/documents/domain/document_limits.dart';

void main() {
  final invalid = throwsA(
    isA<DocumentException>().having(
      (error) => error.code,
      'code',
      'invalid_document_deflate',
    ),
  );
  final overflow = throwsA(
    isA<DocumentException>().having(
      (error) => error.code,
      'code',
      'document_expansion_limit',
    ),
  );

  test('archive encoder stored, fixed and dynamic fixtures validate', () {
    final fixtures = [
      (utf8.encode('stored bytes'), 0, 0),
      (utf8.encode('hello'), 6, 1),
      (
        utf8.encode('the quick brown fox jumps over the lazy dog. ' * 1000),
        6,
        2,
      ),
    ];
    for (final (plain, level, type) in fixtures) {
      final encoded = Deflate(plain, level: level).getBytes();
      expect(
        (encoded.first >> 1) & 3,
        type,
        reason: 'Fixture must exercise the intended block type',
      );
      validateDocumentDeflate(encoded, plain.length);
      expect(Inflate(encoded).getBytes(), plain);
    }
  });

  test('literal-only dynamic tree and empty one-code tree are accepted', () {
    for (final literal in [false, true]) {
      final encoded = _literalDynamic(literal: literal);
      validateDocumentDeflate(encoded, literal ? 1 : 0);
      expect(Inflate(encoded).getBytes(), literal ? [65] : <int>[]);
    }
  });

  test(
    'fixed empty block accepts arbitrary final pad bits but no extra bytes',
    () {
      validateDocumentDeflate(Uint8List.fromList([3, 0]), 0);
      validateDocumentDeflate(Uint8List.fromList([3, 0xfc]), 0);
      expect(
        () => validateDocumentDeflate(Uint8List.fromList([3, 0, 0]), 0),
        invalid,
      );
      expect(
        () => validateDocumentDeflate(Uint8List.fromList([3, 0, 3, 0]), 0),
        invalid,
      );
    },
  );

  test(
    'missing final block, EOB, stored complement and reserved type fail',
    () {
      for (final bytes in [
        <int>[],
        [2, 0],
        [3],
        [7],
        [0, 0, 0, 255, 255],
        [1, 1, 0, 255, 255, 65],
      ]) {
        expect(
          () => validateDocumentDeflate(Uint8List.fromList(bytes), 0),
          invalid,
        );
      }
      expect(
        () =>
            validateDocumentDeflate(Uint8List.fromList([1, 1, 0, 254, 255]), 1),
        invalid,
      );
    },
  );

  test('every truncated prefix of an encoded dynamic stream is rejected', () {
    final plain = utf8.encode(
      'a repeated document paragraph with words. ' * 300,
    );
    final encoded = Deflate(plain).getBytes();
    for (var end = 0; end < encoded.length; end++) {
      expect(
        () => validateDocumentDeflate(
          Uint8List.sublistView(encoded, 0, end),
          plain.length,
        ),
        invalid,
        reason: 'truncated at byte $end',
      );
    }
  });

  test('invalid backward distances and reserved fixed symbols fail', () {
    final noHistory = _BitsWriter()
      ..field(3, 3)
      ..code(1, 7)
      ..code(0, 5);
    final reservedLiteral = _BitsWriter()
      ..field(3, 3)
      ..code(198, 8);
    final reservedDistance = _BitsWriter()
      ..field(3, 3)
      ..code(113, 8)
      ..code(1, 7)
      ..code(30, 5);
    for (final fixture in [noHistory, reservedLiteral, reservedDistance]) {
      expect(() => validateDocumentDeflate(fixture.bytes, 100), invalid);
    }
  });

  test('oversubscribed and incomplete code-length trees are rejected', () {
    for (final lengths in [
      [1, 1, 1, 0],
      [2, 2, 0, 0],
    ]) {
      final bits = _BitsWriter()
        ..field(5, 3)
        ..field(0, 5)
        ..field(0, 5)
        ..field(0, 4);
      for (final length in lengths) {
        bits.field(length, 3);
      }
      expect(() => validateDocumentDeflate(bits.bytes, 0), invalid);
    }
    expect(
      () => validateDocumentDeflate(
        _literalDynamic(literal: true, literalWidth: 2),
        1,
      ),
      invalid,
    );
    expect(
      () => validateDocumentDeflate(
        _literalDynamic(literal: true, extraLiteral: true),
        1,
      ),
      invalid,
    );
  });

  test('dynamic repeat cannot occur before a previous length or overrun', () {
    for (final symbol in [16, 18]) {
      final bits = _BitsWriter()
        ..field(5, 3)
        ..field(0, 5)
        ..field(0, 5)
        ..field(0, 4);
      for (final entry in [16, 17, 18, 0]) {
        bits.field(entry == 0 || entry == symbol ? 1 : 0, 3);
      }
      bits.code(1, 1);
      if (symbol == 18) {
        bits.field(127, 7);
        bits.code(1, 1);
        bits.field(127, 7);
      }
      expect(() => validateDocumentDeflate(bits.bytes, 0), invalid);
    }
  });

  test('stored, literals and matches enforce exact output count', () {
    final stored = Deflate([65], level: 0).getBytes();
    expect(() => validateDocumentDeflate(stored, 0), overflow);
    expect(
      () => validateDocumentDeflate(_literalDynamic(literal: true), 0),
      overflow,
    );
    final matches = _BitsWriter()
      ..field(3, 3)
      ..code(113, 8)
      ..code(1, 7)
      ..code(0, 5)
      ..code(0, 7);
    validateDocumentDeflate(matches.bytes, 4);
    expect(() => validateDocumentDeflate(matches.bytes, 3), overflow);
    expect(() => validateDocumentDeflate(matches.bytes, 5), invalid);
  });
}

// The code-length alphabet contains 0 and literalWidth. Its canonical codes
// are 0 and 1; lengths are written individually to keep fixtures auditable.
Uint8List _literalDynamic({
  required bool literal,
  int literalWidth = 1,
  bool extraLiteral = false,
}) {
  const order = [
    16,
    17,
    18,
    0,
    8,
    7,
    9,
    6,
    10,
    5,
    11,
    4,
    12,
    3,
    13,
    2,
    14,
    1,
    15,
  ];
  final bits = _BitsWriter()
    ..field(5, 3)
    ..field(0, 5)
    ..field(0, 5)
    ..field(14, 4);
  for (final symbol in order.take(18)) {
    bits.field(symbol == 0 || symbol == literalWidth ? 1 : 0, 3);
  }
  for (var symbol = 0; symbol < 258; symbol++) {
    bits.field(
      symbol == 256 ||
              (literal && symbol == 65) ||
              (extraLiteral && symbol == 66)
          ? 1
          : 0,
      1,
    );
  }
  if (literal) bits.code(0, literalWidth);
  bits.code(literal ? 1 : 0, literalWidth);
  return bits.bytes;
}

final class _BitsWriter {
  final List<int> _bytes = [];
  int _position = 0;
  void field(int value, int count) {
    for (var bit = 0; bit < count; bit++) {
      if ((_position & 7) == 0) _bytes.add(0);
      _bytes[_position >> 3] |= ((value >> bit) & 1) << (_position & 7);
      _position++;
    }
  }

  void code(int value, int count) {
    for (var bit = count - 1; bit >= 0; bit--) {
      field((value >> bit) & 1, 1);
    }
  }

  Uint8List get bytes => Uint8List.fromList(_bytes);
}
