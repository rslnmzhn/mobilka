import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mobilka/features/chat/application/image_attachment_processor.dart';

Uint8List _encodeJpeg(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgba(x, y, x % 256, y % 256, 128, 255);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

Uint8List _encodePng(int width, int height) =>
    Uint8List.fromList(img.encodePng(img.Image(width: width, height: height)));

void main() {
  const processor = ImageAttachmentProcessor(maxEdge: 1600, jpegQuality: 85);

  test('oversized jpeg is downscaled and re-encoded as jpeg', () {
    final original = _encodeJpeg(3200, 1600);

    final result = processor.process(
      name: 'photo.jpeg',
      mimeType: 'image/jpeg',
      bytes: original,
    );

    expect(result.processed, isTrue);
    expect(result.mimeType, 'image/jpeg');
    expect(result.name, 'photo.jpeg');
    final decoded = img.decodeImage(result.bytes)!;
    expect(decoded.width, 1600);
    expect(decoded.height, 800);
    expect(result.bytes.length, lessThan(original.length));
    expect(result.originalBytes, original.length);
  });

  test('small png stays untouched', () {
    final original = _encodePng(800, 600);

    final result = processor.process(
      name: 'shot.png',
      mimeType: 'image/png',
      bytes: original,
    );

    expect(result.processed, isFalse);
    expect(identical(result.bytes, original), isTrue);
    expect(result.mimeType, 'image/png');
  });

  test('animated gif passes through without processing', () {
    final bytes = Uint8List.fromList([71, 73, 70, 56, 57]);

    final result = processor.process(
      name: 'anim.gif',
      mimeType: 'image/gif',
      bytes: bytes,
    );

    expect(result.processed, isFalse);
    expect(identical(result.bytes, bytes), isTrue);
  });

  test('undecodable payload claiming to be png passes through', () {
    final bytes = Uint8List.fromList(List.filled(64, 7));

    final result = processor.process(
      name: 'broken.png',
      mimeType: 'image/png',
      bytes: bytes,
    );

    expect(result.processed, isFalse);
    expect(result.bytes, same(bytes));
  });

  test('non-image attachments bypass the processor entirely', () {
    final bytes = Uint8List.fromList(utf8.encode('plain'));

    final result = processor.process(
      name: 'notes.txt',
      mimeType: 'text/plain',
      bytes: bytes,
    );

    expect(result.processed, isFalse);
    expect(String.fromCharCodes(result.bytes), 'plain');
  });
}
