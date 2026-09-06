import 'dart:typed_data';

import '../domain/document_limits.dart';

/// Validates RFC 1951 structure and output size without allocating the output.
/// Archive's inflater does not distinguish malformed termination from BFINAL.
void validateDocumentDeflate(Uint8List bytes, int expectedBytes) {
  final bits = _Bits(bytes);
  var produced = 0;
  void advance(int count) {
    if (count > expectedBytes - produced) {
      throw const DocumentException('document_expansion_limit');
    }
    produced += count;
  }

  var finalBlock = false;
  while (!finalBlock) {
    finalBlock = bits.read(1) == 1;
    final type = bits.read(2);
    if (type == 0) {
      bits.align();
      final length = bits.read(16);
      if ((length ^ bits.read(16)) != 0xffff) _invalid();
      advance(length);
      bits.skipBytes(length);
      continue;
    }
    if (type == 3) _invalid();
    final (_Huffman literals, _Huffman distances) = type == 1
        ? (_fixedLiterals, _fixedDistances)
        : _dynamicTrees(bits);
    while (true) {
      final symbol = literals.decode(bits);
      if (symbol < 256) {
        advance(1);
      } else if (symbol == 256) {
        break;
      } else {
        if (symbol > 285) _invalid();
        final index = symbol - 257;
        final length = _lengthBase[index] + bits.read(_lengthExtra[index]);
        final distanceSymbol = distances.decode(bits);
        if (distanceSymbol > 29) _invalid();
        final distance =
            _distanceBase[distanceSymbol] +
            bits.read(_distanceExtra[distanceSymbol]);
        if (distance > produced || distance > 32768) _invalid();
        advance(length);
      }
    }
  }
  // RFC 1951 leaves the unused high bits of the final byte unspecified.
  // Only those bits may remain, never an additional byte or another stream.
  if ((bits.position + 7) ~/ 8 != bytes.length || produced != expectedBytes) {
    _invalid();
  }
}

(_Huffman, _Huffman) _dynamicTrees(_Bits bits) {
  final literalCount = bits.read(5) + 257;
  final distanceCount = bits.read(5) + 1;
  final codeCount = bits.read(4) + 4;
  if (literalCount > 286) _invalid();
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
  final codes = List<int>.filled(19, 0);
  for (var i = 0; i < codeCount; i++) {
    codes[order[i]] = bits.read(3);
  }
  final codeTree = _Huffman(codes, requireComplete: true);
  final lengths = <int>[];
  final total = literalCount + distanceCount;
  while (lengths.length < total) {
    final symbol = codeTree.decode(bits);
    if (symbol < 16) {
      lengths.add(symbol);
      continue;
    }
    final int count;
    final int value;
    if (symbol == 16) {
      if (lengths.isEmpty) _invalid();
      count = bits.read(2) + 3;
      value = lengths.last;
    } else {
      count = symbol == 17 ? bits.read(3) + 3 : bits.read(7) + 11;
      value = 0;
    }
    if (count > total - lengths.length) _invalid();
    lengths.addAll(List<int>.filled(count, value));
  }
  if (lengths[256] == 0) _invalid();
  return (
    _Huffman(lengths.sublist(0, literalCount)),
    _Huffman(lengths.sublist(literalCount), allowEmpty: true),
  );
}

final class _Bits {
  _Bits(this.bytes);
  final Uint8List bytes;
  int position = 0;

  int read(int count) {
    if (count > bytes.length * 8 - position) _invalid();
    var value = 0;
    for (var i = 0; i < count; i++, position++) {
      value |= ((bytes[position >> 3] >> (position & 7)) & 1) << i;
    }
    return value;
  }

  void align() => position = (position + 7) & ~7;

  void skipBytes(int count) {
    if (count > (bytes.length * 8 - position) ~/ 8) _invalid();
    position += count * 8;
  }
}

final class _Huffman {
  _Huffman(
    List<int> lengths, {
    bool requireComplete = false,
    bool allowEmpty = false,
  }) {
    final counts = List<int>.filled(16, 0);
    for (final length in lengths) {
      if (length < 0 || length > 15) _invalid();
      if (length != 0) counts[length]++;
    }
    var left = 1;
    var maximum = 0;
    for (var length = 1; length <= 15; length++) {
      left = (left << 1) - counts[length];
      if (left < 0) _invalid();
      if (counts[length] != 0) maximum = length;
    }
    if (maximum == 0) {
      if (!allowEmpty) _invalid();
      return;
    }
    // Literal/distance alphabets may have a single one-bit code; the code
    // length alphabet must be complete. Empty distances cannot decode a match.
    if (left != 0 && (requireComplete || maximum != 1)) _invalid();
    _maximum = maximum;
    final next = List<int>.filled(16, 0);
    var code = 0;
    for (var length = 1; length <= 15; length++) {
      code = (code + counts[length - 1]) << 1;
      next[length] = code;
    }
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      final length = lengths[symbol];
      if (length != 0) {
        _symbols[(1 << length) | next[length]++] = symbol;
      }
    }
  }

  final Map<int, int> _symbols = {};
  int _maximum = 0;

  int decode(_Bits bits) {
    var code = 0;
    for (var length = 1; length <= _maximum; length++) {
      // Huffman codes are transmitted most-significant bit first, unlike
      // DEFLATE's numeric fields, despite sharing the little-endian bit pack.
      code = (code << 1) | bits.read(1);
      final symbol = _symbols[(1 << length) | code];
      if (symbol != null) return symbol;
    }
    _invalid();
  }
}

final _fixedLiterals = _Huffman([
  ...List<int>.filled(144, 8),
  ...List<int>.filled(112, 9),
  ...List<int>.filled(24, 7),
  ...List<int>.filled(8, 8),
]);
final _fixedDistances = _Huffman(List<int>.filled(32, 5));
const _lengthBase = [
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  13,
  15,
  17,
  19,
  23,
  27,
  31,
  35,
  43,
  51,
  59,
  67,
  83,
  99,
  115,
  131,
  163,
  195,
  227,
  258,
];
const _lengthExtra = [
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  1,
  1,
  1,
  1,
  2,
  2,
  2,
  2,
  3,
  3,
  3,
  3,
  4,
  4,
  4,
  4,
  5,
  5,
  5,
  5,
  0,
];
const _distanceBase = [
  1,
  2,
  3,
  4,
  5,
  7,
  9,
  13,
  17,
  25,
  33,
  49,
  65,
  97,
  129,
  193,
  257,
  385,
  513,
  769,
  1025,
  1537,
  2049,
  3073,
  4097,
  6145,
  8193,
  12289,
  16385,
  24577,
];
const _distanceExtra = [
  0,
  0,
  0,
  0,
  1,
  1,
  2,
  2,
  3,
  3,
  4,
  4,
  5,
  5,
  6,
  6,
  7,
  7,
  8,
  8,
  9,
  9,
  10,
  10,
  11,
  11,
  12,
  12,
  13,
  13,
];

Never _invalid() => throw const DocumentException('invalid_document_deflate');
