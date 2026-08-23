import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Downscales and re-encodes image attachments before they are Base64-encoded
/// for the provider, keeping conversation memory and request payloads bounded
/// (roadmap item 44; OOM prevention per AGENTS.md known patterns).
///
/// Rules:
/// - Only raster images the `image` package can decode are processed; anything
///   else (including animated GIFs, which would lose animation) passes through
///   untouched.
/// - The longest edge is clamped to [maxEdge] while preserving aspect ratio;
///   smaller images are not upscaled.
/// - JPEG sources are re-encoded as JPEG at [jpegQuality]; every other
///   decodable format is re-encoded as lossless PNG to preserve transparency.
class ImageAttachmentProcessor {
  const ImageAttachmentProcessor({this.maxEdge = 1600, this.jpegQuality = 85});

  final int maxEdge;
  final int jpegQuality;

  bool get isConfigured => maxEdge > 0;

  /// Returns the processed payload, or the original bytes when no
  /// transformation applies.
  ProcessedImage process({
    required String name,
    required String mimeType,
    required Uint8List bytes,
  }) {
    if (!_isRasterImage(mimeType)) {
      return ProcessedImage(
        name: name,
        mimeType: mimeType,
        bytes: bytes,
        processed: false,
      );
    }
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return ProcessedImage(
        name: name,
        mimeType: mimeType,
        bytes: bytes,
        processed: false,
      );
    }
    if (decoded.width <= maxEdge && decoded.height <= maxEdge) {
      return ProcessedImage(
        name: name,
        mimeType: mimeType,
        bytes: bytes,
        processed: false,
      );
    }

    final scale =
        maxEdge /
        (decoded.width > decoded.height ? decoded.width : decoded.height);
    final resized = img.copyResize(
      decoded,
      width: (decoded.width * scale).round(),
      height: (decoded.height * scale).round(),
      interpolation: img.Interpolation.average,
    );

    final keepJpeg = mimeType == 'image/jpeg' || mimeType == 'image/jpg';
    final encoded = keepJpeg
        ? img.encodeJpg(resized, quality: jpegQuality)
        : img.encodePng(resized);

    var outName = name;
    if (keepJpeg &&
        !name.toLowerCase().endsWith('.jpg') &&
        !name.toLowerCase().endsWith('.jpeg')) {
      final dot = name.lastIndexOf('.');
      outName = dot > 0 ? '${name.substring(0, dot)}.jpg' : '$name.jpg';
    }

    return ProcessedImage(
      name: outName,
      mimeType: keepJpeg ? 'image/jpeg' : 'image/png',
      bytes: Uint8List.fromList(encoded),
      processed: true,
      originalBytes: bytes.length,
    );
  }

  String dataUrl(ProcessedImage processed) =>
      'data:${processed.mimeType};base64,${base64Encode(processed.bytes)}';

  bool _isRasterImage(String mimeType) => const {
    'image/png',
    'image/jpeg',
    'image/jpg',
    'image/webp',
    'image/bmp',
    'image/tiff',
  }.contains(mimeType.toLowerCase());
}

class ProcessedImage {
  const ProcessedImage({
    required this.name,
    required this.mimeType,
    required this.bytes,
    required this.processed,
    this.originalBytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;
  final bool processed;
  final int? originalBytes;
}
