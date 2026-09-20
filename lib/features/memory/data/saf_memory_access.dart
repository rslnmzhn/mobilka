import 'dart:io';
import 'dart:typed_data';

import 'package:saf/saf.dart';

abstract interface class SafMemoryAccess {
  Future<List<SafMemoryDocument>> list(String directoryUri);
  Future<Uint8List> read(String documentUri);
  Future<void> delete(String documentUri);
  Future<void> write(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required bool overwrite,
  });

  Future<SafMemoryDocument> createDirectory(String directoryUri, String name);
}

/// Optional SAF operations needed when callers must prove bounded reads and
/// the identity returned by a write. Implementations without this capability
/// remain usable by the legacy memory store, but not by session workspaces.
abstract interface class SafMemoryVerifiedAccess {
  Future<Uint8List> readRange(
    String documentUri, {
    required int start,
    required int count,
  });

  Future<SafMemoryDocument> writeVerified(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required bool overwrite,
  });
}

abstract interface class SafMemoryBinaryAccess {
  Future<SafMemoryDocument> createBinary(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required String mimeType,
    required bool overwrite,
  });

  Future<void> writeBinaryDocument(String documentUri, Uint8List content);
}

class SafMemoryDocument {
  const SafMemoryDocument({
    required this.uri,
    required this.name,
    required this.isDirectory,
    this.mimeType,
    this.size,
  });

  final String uri;
  final String name;
  final bool isDirectory;
  final String? mimeType;
  final int? size;
}

class SafMemoryAccessAdapter
    implements SafMemoryAccess, SafMemoryBinaryAccess, SafMemoryVerifiedAccess {
  SafMemoryAccessAdapter(this._saf);

  final Saf _saf;

  @override
  Future<List<SafMemoryDocument>> list(String directoryUri) async =>
      (await _saf.list(directoryUri))
          .map(
            (document) => SafMemoryDocument(
              uri: document.uri,
              name: document.name,
              isDirectory: document.isDir,
              mimeType: document.mimeType,
              size: document.length,
            ),
          )
          .toList(growable: false);

  @override
  Future<Uint8List> read(String documentUri) => _saf.readFileBytes(documentUri);

  @override
  Future<Uint8List> readRange(
    String documentUri, {
    required int start,
    required int count,
  }) => _saf.readFileBytes(documentUri, start: start, count: count);

  @override
  Future<void> delete(String documentUri) => _saf.delete(documentUri);

  @override
  Future<void> write(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required bool overwrite,
    String? mimeType,
  }) async {
    final effectiveMime = mimeType ?? _detectMimeType(fileName);
    await _saf.writeFileBytes(
      directoryUri,
      fileName,
      effectiveMime,
      content,
      overwrite: overwrite,
    );
  }

  static String _detectMimeType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return switch (ext) {
      'pdf' => 'application/pdf',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'heic' => 'image/heic',
      'heif' => 'image/heif',
      'docx' =>
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xlsx' =>
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'txt' => 'text/plain',
      'csv' => 'text/csv',
      'json' => 'application/json',
      'xml' => 'application/xml',
      'yaml' || 'yml' => 'application/yaml',
      'md' => 'text/markdown',
      _ => 'application/octet-stream',
    };
  }

  @override
  Future<SafMemoryDocument> writeVerified(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required bool overwrite,
  }) async {
    final document = await _saf.writeFileBytes(
      directoryUri,
      fileName,
      'text/plain',
      content,
      overwrite: overwrite,
    );
    return _adapt(document);
  }

  @override
  Future<SafMemoryDocument> createBinary(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required String mimeType,
    required bool overwrite,
  }) async {
    final document = await _saf.writeFileBytes(
      directoryUri,
      fileName,
      mimeType,
      content,
      overwrite: overwrite,
    );
    return _adapt(document);
  }

  @override
  Future<void> writeBinaryDocument(String documentUri, Uint8List content) =>
      _saf.withFileDescriptor(documentUri, 'wt', (descriptor) async {
        await File(descriptor.path).writeAsBytes(content, flush: true);
      });

  @override
  Future<SafMemoryDocument> createDirectory(
    String directoryUri,
    String name,
  ) async {
    final created = await _saf.mkdirp(directoryUri, [name]);
    return _adapt(created);
  }

  SafMemoryDocument _adapt(SafDocumentFile document) => SafMemoryDocument(
    uri: document.uri,
    name: document.name,
    isDirectory: document.isDir,
    mimeType: document.mimeType,
    size: document.length,
  );
}
