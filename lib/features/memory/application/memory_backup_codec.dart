import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../data/memory_repository.dart';

class MemoryBackupCodec {
  const MemoryBackupCodec();

  static const format = 'mobilka-memory-backup';
  static const version = 1;
  static const documentExtension = 'mobilka-memory.json';
  static const maxFileBytes = 1024 * 1024;
  static const maxDocumentBytes = 5 * 1024 * 1024;

  String encode(Map<String, String> files, DateTime createdAt) {
    final manifest = <Map<String, Object>>[];
    for (final name in MemoryRepository.templates.keys) {
      final content = files[name];
      if (content == null) {
        throw const MemoryBackupFormatException('Missing required memory file');
      }
      final bytes = utf8.encode(content);
      if (bytes.length > maxFileBytes) {
        throw MemoryBackupFormatException('$name is too large');
      }
      manifest.add({
        'name': name,
        'bytes': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      });
    }
    return const JsonEncoder.withIndent('  ').convert({
      'format': format,
      'version': version,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'manifest': {'files': manifest},
      'files': files,
    });
  }

  Map<String, String> decode(String document) {
    if (utf8.encode(document).length > maxDocumentBytes) {
      throw const MemoryBackupFormatException('Backup document is too large');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(document);
    } on FormatException catch (error) {
      throw MemoryBackupFormatException('Malformed backup: $error');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != format ||
        decoded['version'] != version) {
      throw const MemoryBackupFormatException('Unsupported backup format');
    }
    final files = decoded['files'];
    final manifest = decoded['manifest'];
    if (files is! Map<String, dynamic> || manifest is! Map<String, dynamic>) {
      throw const MemoryBackupFormatException('Missing files or manifest');
    }
    final expected = MemoryRepository.templates.keys.toSet();
    final actual = files.keys.toSet();
    if (actual.length != expected.length || !actual.containsAll(expected)) {
      throw const MemoryBackupFormatException('Unsafe or missing memory file');
    }
    final entries = manifest['files'];
    if (entries is! List || entries.length != expected.length) {
      throw const MemoryBackupFormatException('Malformed manifest');
    }
    final metadata = <String, Map<String, dynamic>>{};
    for (final entry in entries) {
      if (entry is! Map<String, dynamic> || entry['name'] is! String) {
        throw const MemoryBackupFormatException('Malformed manifest entry');
      }
      final name = entry['name'] as String;
      if (!expected.contains(name) || metadata.containsKey(name)) {
        throw const MemoryBackupFormatException('Unsafe manifest entry');
      }
      metadata[name] = entry;
    }
    final result = <String, String>{};
    for (final name in expected) {
      final content = files[name];
      final entry = metadata[name];
      if (content is! String || entry == null) {
        throw const MemoryBackupFormatException('Malformed file content');
      }
      final bytes = utf8.encode(content);
      if (bytes.length > maxFileBytes) {
        throw MemoryBackupFormatException('$name is too large');
      }
      if (entry['bytes'] != bytes.length ||
          entry['sha256'] != sha256.convert(bytes).toString()) {
        throw MemoryBackupFormatException('Checksum mismatch for $name');
      }
      result[name] = content;
    }
    return Map.unmodifiable(result);
  }
}

class MemoryBackupFormatException implements Exception {
  const MemoryBackupFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}
