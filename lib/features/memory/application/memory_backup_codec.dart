import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/memory_file_names.dart';

class MemoryBackupCodec {
  const MemoryBackupCodec();

  static const format = 'mobilka-memory-backup';
  static const version = 2;
  static const documentExtension = 'mobilka-memory.json';
  static const maxFileBytes = 1024 * 1024;
  static const maxDocumentBytes = 5 * 1024 * 1024;

  String encode(Map<String, String> files, DateTime createdAt) {
    final manifest = <Map<String, Object>>[];
    final backupNames = files.keys.toList()..sort();
    for (final name in backupNames) {
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
    final decoded = _decodeDocument(document);
    final (:files, :manifest) = _readPayload(decoded);
    final actual = files.keys.toSet();
    final isV2 = decoded['version'] == version;
    final dynamicV2 =
        isV2 &&
        actual.containsAll(MemoryFiles.coreBackupFiles) &&
        actual.every(
          (name) =>
              MemoryFiles.coreBackupFiles.contains(name) ||
              RegExp(
                r'^personas/[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?\.md$',
              ).hasMatch(name),
        );
    final supported = isV2
        ? [if (dynamicV2) actual]
        : [
            MemoryFiles.coreBackupFiles,
            {...MemoryFiles.coreBackupFiles, MemoryFiles.legacyPersonas},
          ];
    final expected = supported.firstWhere(
      (set) => actual.length == set.length && actual.containsAll(set),
      orElse: () => const <String>{},
    );
    if (expected.isEmpty) {
      throw const MemoryBackupFormatException('Unsafe or missing memory file');
    }
    _validateFileNames(files, expected);
    final metadata = _readManifest(manifest, expected);
    return Map.unmodifiable(_readFiles(files, metadata, expected));
  }

  Map<String, dynamic> _decodeDocument(String document) {
    final Object? decoded;
    try {
      decoded = jsonDecode(document);
    } on FormatException catch (error) {
      throw MemoryBackupFormatException('Malformed backup: $error');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != format ||
        (decoded['version'] != 1 && decoded['version'] != version)) {
      throw const MemoryBackupFormatException('Unsupported backup format');
    }
    return decoded;
  }

  ({Map<String, dynamic> files, Map<String, dynamic> manifest}) _readPayload(
    Map<String, dynamic> decoded,
  ) {
    final files = decoded['files'];
    final manifest = decoded['manifest'];
    if (files is! Map<String, dynamic> || manifest is! Map<String, dynamic>) {
      throw const MemoryBackupFormatException('Missing files or manifest');
    }
    return (files: files, manifest: manifest);
  }

  void _validateFileNames(Map<String, dynamic> files, Set<String> expected) {
    final actual = files.keys.toSet();
    if (actual.length != expected.length || !actual.containsAll(expected)) {
      throw const MemoryBackupFormatException('Unsafe or missing memory file');
    }
  }

  Map<String, Map<String, dynamic>> _readManifest(
    Map<String, dynamic> manifest,
    Set<String> expected,
  ) {
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
    return metadata;
  }

  Map<String, String> _readFiles(
    Map<String, dynamic> files,
    Map<String, Map<String, dynamic>> metadata,
    Set<String> expected,
  ) {
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
    return result;
  }
}

class MemoryBackupFormatException implements Exception {
  const MemoryBackupFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}
