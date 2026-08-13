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

abstract interface class MissingAwareMemoryFileTransaction {
  Future<String?> readIfExists(String fileName);
}

abstract interface class MemoryFileStore implements MemoryFileBoundary {
  Future<void> createIfMissing(String fileName, String content);
}

const maxMemoryFileBytes = 1024 * 1024;

class PathMemoryFileStore implements MemoryFileStore {
  PathMemoryFileStore(this.directoryPath);

  final String directoryPath;
  static final Map<String, Lock> _directoryLocks = {};

  @override
  Future<String> read(String fileName) {
    _validateFileName(fileName);
    return transaction((files) => files.read(fileName));
  }

  @override
  Future<void> write(String fileName, String content) {
    _validateFileName(fileName);
    return transaction((files) => files.write(fileName, content));
  }

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
        await transaction.write(fileName, content);
      } else if (type != FileSystemEntityType.file) {
        throw const FileSystemException('Unsafe memory file target');
      }
    });
  }
}

class _PathMemoryFileTransaction
    implements MemoryFileTransaction, MissingAwareMemoryFileTransaction {
  const _PathMemoryFileTransaction(this.directoryPath);

  final String directoryPath;

  File target(String fileName) {
    _validateFileName(fileName);
    return File('$directoryPath${Platform.pathSeparator}$fileName');
  }

  @override
  Future<String> read(String fileName) async {
    final file = target(fileName);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FileSystemException('Unsafe memory file target');
    }
    final bytes = await file.readAsBytes();
    return _decodeMemoryFile(bytes);
  }

  @override
  Future<String?> readIfExists(String fileName) async {
    final file = target(fileName);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw const FileSystemException('Unsafe memory file target');
    }
    return _decodeMemoryFile(await file.readAsBytes());
  }

  @override
  Future<void> write(String fileName, String content) async {
    final file = target(fileName);
    final bytes = _encodeMemoryFile(content);
    final temporary = File(
      '$directoryPath${Platform.pathSeparator}.$fileName.'
      '${DateTime.now().microsecondsSinceEpoch}.${identityHashCode(this)}.tmp',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      // Dart has no portable no-follow open. Revalidate immediately before an
      // atomic replacement so the checked target is never reopened or followed.
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.notFound) {
        throw const FileSystemException('Unsafe memory file target');
      }
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
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
  Future<String> read(String fileName) {
    _validateFileName(fileName);
    return transaction((files) => files.read(fileName));
  }

  @override
  Future<void> write(String fileName, String content) {
    _validateFileName(fileName);
    return transaction((files) => files.write(fileName, content));
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) {
    return _lock.synchronized(() async {
      final documents = await _access.list(directoryUri);
      return action(
        _SafMemoryFileTransaction(directoryUri, _access, documents),
      );
    });
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

class _SafMemoryFileTransaction
    implements MemoryFileTransaction, MissingAwareMemoryFileTransaction {
  _SafMemoryFileTransaction(this.directoryUri, this.access, this.documents);

  final String directoryUri;
  final SafMemoryAccess access;
  final List<SafMemoryDocument> documents;

  @override
  Future<String> read(String fileName) async {
    _validateFileName(fileName);
    final matches = documents.where((document) => document.name == fileName);
    if (matches.length != 1 || matches.single.isDirectory) {
      throw StateError('Memory file not found or ambiguous: $fileName');
    }
    return _decodeMemoryFile(await access.read(matches.single.uri));
  }

  @override
  Future<String?> readIfExists(String fileName) async {
    _validateFileName(fileName);
    final matches = documents
        .where((document) => document.name == fileName)
        .toList();
    if (matches.isEmpty) return null;
    if (matches.length != 1 || matches.single.isDirectory) {
      throw StateError('Memory file is ambiguous or unsafe: $fileName');
    }
    return _decodeMemoryFile(await access.read(matches.single.uri));
  }

  @override
  Future<void> write(String fileName, String content) async {
    _validateFileName(fileName);
    await access.write(
      directoryUri,
      fileName,
      _encodeMemoryFile(content),
      overwrite: true,
    );
  }
}

Uint8List _encodeMemoryFile(String content) {
  final bytes = utf8.encode(content);
  if (bytes.length > maxMemoryFileBytes) {
    throw const FormatException('Memory file exceeds the size limit');
  }
  return Uint8List.fromList(bytes);
}

String _decodeMemoryFile(List<int> bytes) {
  if (bytes.length > maxMemoryFileBytes) {
    throw const FormatException('Memory file exceeds the size limit');
  }
  return utf8.decode(bytes, allowMalformed: false);
}

bool _isSafeMarkdownName(String fileName) =>
    RegExp(r'^[a-z0-9][a-z0-9_-]*\.md$').hasMatch(fileName) &&
    !fileName.contains('..');

void _validateFileName(String fileName) {
  if (!_isSafeMarkdownName(fileName)) {
    throw const FormatException('Invalid memory file name');
  }
}
