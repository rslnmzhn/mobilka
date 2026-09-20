import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../memory/data/memory_file_store.dart';
import '../domain/chat_message.dart';

/// Copies originals into the bound session before a request is admitted.
Future<List<ChatAttachment>> storeChatAttachments({
  required List<ChatAttachment> attachments,
  required String sessionKey,
  required Future<bool> Function(String path, Uint8List bytes, String mimeType)
  write,
}) async {
  final saved = <ChatAttachment>[];
  final random = Random.secure();
  for (final attachment in attachments) {
    final prepared = await compute(_decodeAttachment, attachment.dataBase64);
    final bytes = prepared.$1;
    // Sanitize the original file name while preserving readable identity and extension.
    final safeOriginal = attachment.name
        .replaceAll(RegExp(r'[^a-zA-Z0-9а-яА-ЯёЁ_.-]'), '_')
        .replaceAll('..', '_');
    final shortId = List.generate(
      4,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final name = 'att_${shortId}_$safeOriginal';
    final relativePath = 'artifacts/$name';
    final fullPath = 'sessions/$sessionKey/$relativePath';
    if (MemoryFileValidation.subPath(fullPath) == null) {
      throw const FormatException('Invalid attachment workspace path');
    }
    final written = await write(fullPath, bytes, attachment.mimeType);
    if (!written) throw StateError('Attachment workspace write failed');
    saved.add(attachment.withWorkspace(relativePath, prepared.$2));
  }
  return List.unmodifiable(saved);
}

(Uint8List, String) _decodeAttachment(String encoded) {
  if (encoded.length > ((maxAttachmentBytes + 2) ~/ 3) * 4) {
    throw const FormatException('Attachment exceeds the size limit');
  }
  final bytes = base64Decode(encoded);
  if (bytes.length > maxAttachmentBytes) {
    throw const FormatException('Attachment exceeds the size limit');
  }
  return (bytes, sha256.convert(bytes).toString());
}
