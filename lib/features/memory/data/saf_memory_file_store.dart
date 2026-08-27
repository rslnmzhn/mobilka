import 'dart:typed_data';

import 'package:saf/saf.dart';
import 'package:synchronized/synchronized.dart';

import 'memory_file_store_contracts.dart';

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

  /// Creates one direct child. The caller verifies it by re-listing the parent
  /// because SAF providers do not consistently expose parent metadata.
  Future<SafMemoryDocument> createDirectory(String directoryUri, String name);
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
  Future<SafMemoryDocument> createDirectory(
    String directoryUri,
    String name,
  ) async {
    final created = await _saf.mkdirp(directoryUri, [name]);
    return SafMemoryDocument(
      uri: created.uri,
      name: created.name,
      isDirectory: created.isDir,
    );
  }
}

class SafMemoryFileStore implements MemoryFileStore, SubPathMemoryFileBoundary {
  SafMemoryFileStore(this.directoryUri, this._access);

  final String directoryUri;
  final SafMemoryAccess _access;
  static final Map<String, Lock> _directoryLocks = {};
  Lock get _lock => _directoryLocks.putIfAbsent(directoryUri, Lock.new);

  @override
  Future<String> read(String fileName) {
    MemoryFileValidation.validateFileName(fileName);
    return transaction((files) => files.read(fileName));
  }

  @override
  Future<void> write(String fileName, String content) {
    MemoryFileValidation.validateFileName(fileName);
    return transaction((files) => files.write(fileName, content));
  }

  @override
  Future<void> delete(String fileName) {
    MemoryFileValidation.validateFileName(fileName);
    return _lock.synchronized(() async {
      final matches = (await _access.list(
        directoryUri,
      )).where((document) => document.name == fileName).toList();
      if (matches.length == 1 && !matches.single.isDirectory) {
        await _access.delete(matches.single.uri);
      }
    });
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) => _lock.synchronized(() async {
    final documents = await _access.list(directoryUri);
    return action(_SafMemoryFileTransaction(directoryUri, _access, documents));
  });

  @override
  Future<void> createIfMissing(String fileName, String content) {
    MemoryFileValidation.validateFileName(fileName);
    return _lock.synchronized(() async {
      final matches = (await _access.list(
        directoryUri,
      )).where((document) => document.name == fileName).toList();
      if (matches.isNotEmpty) {
        if (matches.length != 1 || matches.single.isDirectory) {
          throw StateError('Memory file is ambiguous or unsafe: $fileName');
        }
        return;
      }
      await _access.write(
        directoryUri,
        fileName,
        MemoryFileCodec.encode(content),
        overwrite: false,
      );
    });
  }

  @override
  Future<String?> readSubPath(String relativePath) async {
    final parts = MemoryFileValidation.subPath(relativePath);
    if (parts == null) return null;
    return _lock.synchronized(() async {
      final parent = await _findParent(parts);
      if (parent == null) return null;
      final leaf = await _resolveExactChild(
        parent,
        parts.last,
        expectedDirectory: false,
        allowMissing: true,
      );
      if (leaf == null) return null;
      return MemoryFileCodec.decode(await _access.read(leaf.uri));
    });
  }

  @override
  Future<bool> writeSubPath(String relativePath, String content) async {
    final parts = MemoryFileValidation.subPath(relativePath);
    if (parts == null) return false;
    return _lock.synchronized(() async {
      final parent = await _resolveOrCreateDirectories(
        parts.sublist(0, parts.length - 1),
      );
      await _resolveExactChild(
        parent,
        parts.last,
        expectedDirectory: false,
        allowMissing: true,
      );
      await _access.write(
        parent,
        parts.last,
        MemoryFileCodec.encode(content),
        overwrite: true,
      );
      return true;
    });
  }

  @override
  Future<List<String>> listSubPath(String relativeDirectory) async {
    final parts = MemoryFileValidation.listSubPath(relativeDirectory);
    if (parts == null) return const [];
    return _lock.synchronized(() async {
      var current = directoryUri;
      for (final part in parts) {
        final child = await _resolveExactChild(
          current,
          part,
          expectedDirectory: true,
          allowMissing: true,
        );
        if (child == null) return const <String>[];
        current = child.uri;
      }
      final children = await _access.list(current);
      final names = children
          .where((item) => MemoryFileValidation.isSafeSkillFileName(item.name))
          .map((item) => item.name)
          .toSet()
          .toList();
      for (final name in names) {
        await _resolveExactChild(
          current,
          name,
          expectedDirectory: false,
          allowMissing: false,
          children: children,
        );
      }
      names.sort();
      return names;
    });
  }

  Future<String?> _findParent(List<String> parts) async {
    var current = directoryUri;
    for (final directory in parts.sublist(0, parts.length - 1)) {
      final child = await _resolveExactChild(
        current,
        directory,
        expectedDirectory: true,
        allowMissing: true,
      );
      if (child == null) return null;
      current = child.uri;
    }
    return current;
  }

  Future<String> _resolveOrCreateDirectories(List<String> parts) async {
    var current = directoryUri;
    for (final part in parts) {
      final existing = await _resolveExactChild(
        current,
        part,
        expectedDirectory: true,
        allowMissing: true,
      );
      if (existing != null) {
        current = existing.uri;
        continue;
      }
      final created = await _access.createDirectory(current, part);
      if (!created.isDirectory || created.name != part) {
        throw StateError('SAF provider returned an invalid directory');
      }
      final verified = await _resolveExactChild(
        current,
        part,
        expectedDirectory: true,
        allowMissing: false,
      );
      if (verified!.uri != created.uri) {
        throw StateError('SAF provider could not prove directory parentage');
      }
      current = created.uri;
    }
    return current;
  }

  Future<SafMemoryDocument?> _resolveExactChild(
    String parentUri,
    String name, {
    required bool expectedDirectory,
    required bool allowMissing,
    List<SafMemoryDocument>? children,
  }) async {
    final matches = (children ?? await _access.list(parentUri))
        .where((document) => document.name == name)
        .toList();
    if (matches.isEmpty && allowMissing) return null;
    if (matches.length != 1) {
      throw StateError('Workspace child is missing or ambiguous: $name');
    }
    final child = matches.single;
    if (child.isDirectory != expectedDirectory) {
      throw StateError('Workspace child has an unexpected type: $name');
    }
    return child;
  }
}

class _SafMemoryFileTransaction
    implements
        MemoryFileTransaction,
        MissingAwareMemoryFileTransaction,
        DeletingMemoryFileTransaction {
  _SafMemoryFileTransaction(this.directoryUri, this.access, this.documents);
  final String directoryUri;
  final SafMemoryAccess access;
  final List<SafMemoryDocument> documents;

  List<SafMemoryDocument> _matches(String fileName) {
    MemoryFileValidation.validateFileName(fileName);
    return documents.where((document) => document.name == fileName).toList();
  }

  @override
  Future<String> read(String fileName) async {
    final matches = _matches(fileName);
    if (matches.length != 1 || matches.single.isDirectory) {
      throw StateError('Memory file not found or ambiguous: $fileName');
    }
    return MemoryFileCodec.decode(await access.read(matches.single.uri));
  }

  @override
  Future<String?> readIfExists(String fileName) async {
    final matches = _matches(fileName);
    if (matches.isEmpty) return null;
    if (matches.length != 1 || matches.single.isDirectory) {
      throw StateError('Memory file is ambiguous or unsafe: $fileName');
    }
    return MemoryFileCodec.decode(await access.read(matches.single.uri));
  }

  @override
  Future<void> write(String fileName, String content) async {
    MemoryFileValidation.validateFileName(fileName);
    await access.write(
      directoryUri,
      fileName,
      MemoryFileCodec.encode(content),
      overwrite: true,
    );
  }

  @override
  Future<void> delete(String fileName) async {
    final matches = _matches(fileName);
    if (matches.isEmpty) return;
    if (matches.length != 1 || matches.single.isDirectory) {
      throw StateError('Memory file is ambiguous or unsafe: $fileName');
    }
    await access.delete(matches.single.uri);
    documents.remove(matches.single);
  }
}
