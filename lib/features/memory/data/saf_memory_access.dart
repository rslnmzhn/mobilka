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
  });

  final String uri;
  final String name;
  final bool isDirectory;
  final String? mimeType;
}

class SafMemoryAccessAdapter implements SafMemoryAccess, SafMemoryBinaryAccess {
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
            ),
          )
          .toList(growable: false);

  @override
  Future<Uint8List> read(String documentUri) => _saf.readFileBytes(documentUri);

  @override
  Future<void> delete(String documentUri) => _saf.delete(documentUri);

  @override
  Future<void> write(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required bool overwrite,
  }) async {
    await _saf.writeFileBytes(
      directoryUri,
      fileName,
      'text/markdown',
      content,
      overwrite: overwrite,
    );
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
    return SafMemoryDocument(
      uri: document.uri,
      name: document.name,
      isDirectory: document.isDir,
      mimeType: document.mimeType,
    );
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
    return SafMemoryDocument(
      uri: created.uri,
      name: created.name,
      isDirectory: created.isDir,
      mimeType: created.mimeType,
    );
  }
}
