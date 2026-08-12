import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:saf/saf.dart';
import 'package:synchronized/synchronized.dart';

abstract interface class MemoryFileBoundary {
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  );

  Future<String> read(String fileName);
  Future<void> write(String fileName, String content);
}

abstract interface class MemoryFileTransaction {
  Future<String> read(String fileName);
  Future<void> write(String fileName, String content);
}

abstract interface class MemoryFileStore implements MemoryFileBoundary {
  Future<void> createIfMissing(String fileName, String content);
}

class PathMemoryFileStore implements MemoryFileStore {
  PathMemoryFileStore(this.directoryPath);

  final String directoryPath;
  static final Map<String, Lock> _directoryLocks = {};

  @override
  Future<String> read(String fileName) =>
      transaction((files) => files.read(fileName));

  @override
  Future<void> write(String fileName, String content) =>
      transaction((files) => files.write(fileName, content));

  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) async {
    final canonicalDirectory = await Directory(
      directoryPath,
    ).resolveSymbolicLinks();
    final lock = _directoryLocks.putIfAbsent(canonicalDirectory, Lock.new);
    return lock.synchronized(
      () => action(_PathMemoryFileTransaction(canonicalDirectory)),
    );
  }

  @override
  Future<void> createIfMissing(String fileName, String content) async {
    await transaction((files) async {
      final transaction = files as _PathMemoryFileTransaction;
      final file = transaction.target(fileName);
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await file.writeAsString(content, flush: true);
      } else if (type != FileSystemEntityType.file) {
        throw const FileSystemException('Unsafe memory file target');
      }
    });
  }
}

class _PathMemoryFileTransaction implements MemoryFileTransaction {
  const _PathMemoryFileTransaction(this.directoryPath);

  final String directoryPath;

  File target(String fileName) {
    _validateFileName(fileName);
    return File('$directoryPath${Platform.pathSeparator}$fileName');
  }

  @override
  Future<String> read(String fileName) => target(fileName).readAsString();

  @override
  Future<void> write(String fileName, String content) async {
    final file = target(fileName);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw const FileSystemException('Unsafe memory file target');
    }
    await file.writeAsString(content, flush: true);
  }
}

abstract interface class SafMemoryAccess {
  Future<List<SafMemoryDocument>> list(String directoryUri);
  Future<Uint8List> read(String documentUri);
  Future<void> write(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required bool overwrite,
  });
}

class SafMemoryDocument {
  const SafMemoryDocument({
    required this.uri,
    required this.name,
    required this.isDirectory,
  });

  final String uri;
  final String name;
  final bool isDirectory;
}

class SafMemoryAccessAdapter implements SafMemoryAccess {
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
            ),
          )
          .toList(growable: false);

  @override
  Future<Uint8List> read(String documentUri) => _saf.readFileBytes(documentUri);

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
}

class SafMemoryFileStore implements MemoryFileStore {
  SafMemoryFileStore(this.directoryUri, this._access);

  final String directoryUri;
  final SafMemoryAccess _access;
  static final Map<String, Lock> _directoryLocks = {};

  Lock get _lock => _directoryLocks.putIfAbsent(directoryUri, Lock.new);

  @override
  Future<String> read(String fileName) =>
      transaction((files) => files.read(fileName));

  @override
  Future<void> write(String fileName, String content) =>
      transaction((files) => files.write(fileName, content));

  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) {
    return _lock.synchronized(
      () => action(_SafMemoryFileTransaction(directoryUri, _access)),
    );
  }

  @override
  Future<void> createIfMissing(String fileName, String content) {
    _validateFileName(fileName);
    return _lock.synchronized(() async {
      final documents = await _access.list(directoryUri);
      final matches = documents.where((document) => document.name == fileName);
      if (matches.isNotEmpty) {
        if (matches.length != 1 || matches.single.isDirectory) {
          throw StateError('Memory file is ambiguous or unsafe: $fileName');
        }
        return;
      }
      await _access.write(
        directoryUri,
        fileName,
        Uint8List.fromList(utf8.encode(content)),
        overwrite: false,
      );
    });
  }
}

class _SafMemoryFileTransaction implements MemoryFileTransaction {
  const _SafMemoryFileTransaction(this.directoryUri, this.access);

  final String directoryUri;
  final SafMemoryAccess access;

  @override
  Future<String> read(String fileName) async {
    _validateFileName(fileName);
    final documents = await access.list(directoryUri);
    final matches = documents.where(
      (document) => !document.isDirectory && document.name == fileName,
    );
    if (matches.length != 1) {
      throw StateError('Memory file not found or ambiguous: $fileName');
    }
    return utf8.decode(await access.read(matches.single.uri));
  }

  @override
  Future<void> write(String fileName, String content) async {
    _validateFileName(fileName);
    await access.write(
      directoryUri,
      fileName,
      Uint8List.fromList(utf8.encode(content)),
      overwrite: true,
    );
  }
}

bool _isSafeMarkdownName(String fileName) =>
    RegExp(r'^[a-z0-9][a-z0-9_-]*\.md$').hasMatch(fileName) &&
    !fileName.contains('..');

void _validateFileName(String fileName) {
  if (!_isSafeMarkdownName(fileName)) {
    throw const FormatException('Invalid memory file name');
  }
}
