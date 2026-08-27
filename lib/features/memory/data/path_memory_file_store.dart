import 'dart:io';

import 'package:synchronized/synchronized.dart';

import 'memory_file_store_contracts.dart';

/// Test seam for modeling substitutions at the narrow remaining Dart I/O race.
class PathMemoryFileStoreHooks {
  const PathMemoryFileStoreHooks({this.afterTemporaryCreated});

  final Future<void> Function(File temporary, File destination)?
  afterTemporaryCreated;
}

class PathMemoryFileStore
    implements
        MemoryFileStore,
        SubPathMemoryFileBoundary,
        BinarySubPathMemoryFileBoundary {
  PathMemoryFileStore(this.directoryPath, {PathMemoryFileStoreHooks? hooks})
    : _hooks = hooks;

  final String directoryPath;
  final PathMemoryFileStoreHooks? _hooks;
  static final Map<String, Lock> _directoryLocks = {};

  String get rootPath => directoryPath;

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
    return transaction((files) async {
      await (files as _PathMemoryFileTransaction).delete(fileName);
    });
  }

  @override
  Future<String?> readSubPath(String relativePath) async {
    final parts = MemoryFileValidation.subPath(relativePath);
    if (parts == null) return null;
    return _withCanonicalRoot((guard) async {
      final parent = await guard.parent(parts, create: false);
      if (parent == null) return null;
      final file = File(_join(parent.path, parts.last));
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return null;
      if (type != FileSystemEntityType.file) throw _unsafeFile();
      await guard.revalidateParent(parts, parent.path);
      return MemoryFileCodec.decode(await file.readAsBytes());
    });
  }

  @override
  Future<bool> writeSubPath(String relativePath, String content) async {
    final parts = MemoryFileValidation.subPath(relativePath);
    if (parts == null) return false;
    return _withCanonicalRoot((guard) async {
      final parent = await guard.parent(parts, create: true);
      if (parent == null) return false;
      final file = File(_join(parent.path, parts.last));
      await _atomicWrite(
        guard: guard,
        parentParts: parts,
        canonicalParent: parent.path,
        destination: file,
        bytes: MemoryFileCodec.encode(content),
      );
      return true;
    });
  }

  @override
  Future<WorkspacePairWriteResult> writeBinaryPair(
    WorkspaceBinaryFile first,
    WorkspaceBinaryFile second,
  ) async {
    first.validate();
    second.validate();
    final firstParts = MemoryFileValidation.subPath(first.relativePath)!;
    final secondParts = MemoryFileValidation.subPath(second.relativePath)!;
    return _withCanonicalRoot((guard) async {
      var firstStatus = WorkspaceSiblingWriteStatus.definitelyNotWritten;
      var writeAttempted = false;
      try {
        final firstParent = await guard.parent(firstParts, create: true);
        final secondParent = await guard.parent(secondParts, create: true);
        if (firstParent == null ||
            secondParent == null ||
            !_samePath(firstParent.path, secondParent.path)) {
          throw _unsafeParent();
        }
        await guard.revalidateParent(firstParts, firstParent.path);
        for (final parts in [firstParts, secondParts]) {
          final type = await FileSystemEntity.type(
            _join(firstParent.path, parts.last),
            followLinks: false,
          );
          if (type == FileSystemEntityType.file) {
            return const WorkspacePairWriteResult(
              firstStatus: WorkspaceSiblingWriteStatus.collision,
              secondStatus: WorkspaceSiblingWriteStatus.collision,
            );
          }
          if (type != FileSystemEntityType.notFound) throw _unsafeFile();
        }
        await guard.revalidateParent(firstParts, firstParent.path);
        for (final entry in [(firstParts, first), (secondParts, second)]) {
          final parts = entry.$1;
          final payload = entry.$2;
          final parent = await guard.parent(parts, create: true);
          if (parent == null) {
            return WorkspacePairWriteResult(
              firstStatus: firstStatus,
              secondStatus: WorkspaceSiblingWriteStatus.definitelyNotWritten,
            );
          }
          writeAttempted = true;
          await _atomicWrite(
            guard: guard,
            parentParts: parts,
            canonicalParent: parent.path,
            destination: File(_join(parent.path, parts.last)),
            bytes: payload.bytes,
            overwrite: false,
          );
          if (firstStatus != WorkspaceSiblingWriteStatus.verifiedWritten) {
            firstStatus = WorkspaceSiblingWriteStatus.verifiedWritten;
            writeAttempted = false;
          } else {
            return const WorkspacePairWriteResult(
              firstStatus: WorkspaceSiblingWriteStatus.verifiedWritten,
              secondStatus: WorkspaceSiblingWriteStatus.verifiedWritten,
            );
          }
        }
      } catch (_) {
        if (writeAttempted) {
          return WorkspacePairWriteResult(
            firstStatus:
                firstStatus == WorkspaceSiblingWriteStatus.verifiedWritten
                ? firstStatus
                : WorkspaceSiblingWriteStatus.indeterminate,
            secondStatus:
                firstStatus == WorkspaceSiblingWriteStatus.verifiedWritten
                ? WorkspaceSiblingWriteStatus.indeterminate
                : WorkspaceSiblingWriteStatus.definitelyNotWritten,
          );
        }
        return WorkspacePairWriteResult(
          firstStatus: WorkspaceSiblingWriteStatus.indeterminate,
          secondStatus: WorkspaceSiblingWriteStatus.indeterminate,
        );
      }
      return WorkspacePairWriteResult(
        firstStatus: firstStatus,
        secondStatus: WorkspaceSiblingWriteStatus.definitelyNotWritten,
      );
    });
  }

  @override
  Future<List<String>> listSubPath(String relativeDirectory) async {
    final parts = MemoryFileValidation.listSubPath(relativeDirectory);
    if (parts == null) return const [];
    return _withCanonicalRoot((guard) async {
      final sentinel = [...parts, 'entry.md'];
      final directory = await guard.parent(sentinel, create: false);
      if (directory == null) return const [];
      await guard.revalidateParent(sentinel, directory.path);
      final entries = <String>[];
      await for (final entity in directory.list(followLinks: false)) {
        if (await FileSystemEntity.type(entity.path, followLinks: false) ==
            FileSystemEntityType.file) {
          final name = entity.uri.pathSegments.last;
          if (MemoryFileValidation.isSafeSkillFileName(name)) entries.add(name);
        }
      }
      entries.sort();
      return entries;
    });
  }

  Future<T> _withCanonicalRoot<T>(
    Future<T> Function(_CanonicalPathGuard guard) action,
  ) async {
    final root = await Directory(directoryPath).resolveSymbolicLinks();
    final lock = _directoryLocks.putIfAbsent(_lockKey(root), Lock.new);
    return lock.synchronized(() async {
      final guard = _CanonicalPathGuard(directoryPath, root);
      await guard.revalidateRoot();
      return action(guard);
    });
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) => _withCanonicalRoot(
    (guard) => action(_PathMemoryFileTransaction(guard, _hooks)),
  );

  @override
  Future<void> createIfMissing(String fileName, String content) async {
    MemoryFileValidation.validateFileName(fileName);
    await transaction((files) async {
      final transaction = files as _PathMemoryFileTransaction;
      final type = await transaction.targetType(fileName);
      if (type == FileSystemEntityType.notFound) {
        await transaction.write(fileName, content);
      } else if (type != FileSystemEntityType.file) {
        throw _unsafeFile();
      }
    });
  }

  Future<void> _atomicWrite({
    required _CanonicalPathGuard guard,
    required List<String> parentParts,
    required String canonicalParent,
    required File destination,
    required List<int> bytes,
    bool overwrite = true,
  }) async {
    final temporary = File(
      _join(
        canonicalParent,
        '.${destination.uri.pathSegments.last}.'
        '${DateTime.now().microsecondsSinceEpoch}.${identityHashCode(this)}.tmp',
      ),
    );
    try {
      await guard.revalidateParent(parentParts, canonicalParent);
      await temporary.writeAsBytes(bytes, flush: true);
      await _hooks?.afterTemporaryCreated?.call(temporary, destination);
      await guard.revalidateParent(parentParts, canonicalParent);
      if (await FileSystemEntity.type(temporary.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw _unsafeFile();
      }
      if (!_samePath(
        await temporary.parent.resolveSymbolicLinks(),
        canonicalParent,
      )) {
        throw _unsafeParent();
      }
      final type = await FileSystemEntity.type(
        destination.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.notFound) {
        throw _unsafeFile();
      }
      await guard.revalidateParent(parentParts, canonicalParent);
      if (overwrite) {
        await temporary.rename(destination.path);
      } else {
        await destination.create(exclusive: true);
        await destination.writeAsBytes(bytes, flush: true);
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

class _PathMemoryFileTransaction
    implements
        MemoryFileTransaction,
        MissingAwareMemoryFileTransaction,
        DeletingMemoryFileTransaction {
  const _PathMemoryFileTransaction(this.guard, this.hooks);

  final _CanonicalPathGuard guard;
  final PathMemoryFileStoreHooks? hooks;

  File target(String fileName) {
    MemoryFileValidation.validateFileName(fileName);
    return File(_join(guard.canonicalRoot, fileName));
  }

  Future<FileSystemEntityType> targetType(String fileName) async {
    await guard.revalidateRoot();
    return FileSystemEntity.type(target(fileName).path, followLinks: false);
  }

  @override
  Future<String> read(String fileName) async {
    final file = target(fileName);
    if (await targetType(fileName) != FileSystemEntityType.file) {
      throw _unsafeFile();
    }
    await guard.revalidateRoot();
    return MemoryFileCodec.decode(await file.readAsBytes());
  }

  @override
  Future<String?> readIfExists(String fileName) async {
    final file = target(fileName);
    final type = await targetType(fileName);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) throw _unsafeFile();
    await guard.revalidateRoot();
    return MemoryFileCodec.decode(await file.readAsBytes());
  }

  @override
  Future<void> write(String fileName, String content) async {
    final store = PathMemoryFileStore(guard.configuredRoot, hooks: hooks);
    await store._atomicWrite(
      guard: guard,
      parentParts: [fileName],
      canonicalParent: guard.canonicalRoot,
      destination: target(fileName),
      bytes: MemoryFileCodec.encode(content),
    );
  }

  @override
  Future<void> delete(String fileName) async {
    final file = target(fileName);
    final type = await targetType(fileName);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) throw _unsafeFile();
    await guard.revalidateRoot();
    await file.delete();
  }
}

class _CanonicalPathGuard {
  const _CanonicalPathGuard(this.configuredRoot, this.canonicalRoot);

  final String configuredRoot;
  final String canonicalRoot;

  Future<void> revalidateRoot() async {
    final type = await FileSystemEntity.type(
      configuredRoot,
      followLinks: false,
    );
    if (type != FileSystemEntityType.directory ||
        !_samePath(
          await Directory(configuredRoot).resolveSymbolicLinks(),
          canonicalRoot,
        )) {
      throw _unsafeParent();
    }
  }

  Future<Directory?> parent(List<String> parts, {required bool create}) async {
    await revalidateRoot();
    var current = Directory(canonicalRoot);
    for (final part in parts.take(parts.length - 1)) {
      final next = Directory(_join(current.path, part));
      var type = await FileSystemEntity.type(next.path, followLinks: false);
      if (type == FileSystemEntityType.notFound && create) {
        await revalidateRoot();
        await next.create();
        type = await FileSystemEntity.type(next.path, followLinks: false);
      }
      if (type == FileSystemEntityType.notFound) return null;
      if (type != FileSystemEntityType.directory) throw _unsafeParent();
      final resolved = await next.resolveSymbolicLinks();
      if (!_withinRoot(canonicalRoot, resolved)) throw _unsafeParent();
      current = Directory(resolved);
    }
    await revalidateRoot();
    return current;
  }

  Future<void> revalidateParent(
    List<String> parts,
    String expectedCanonicalParent,
  ) async {
    final current = await parent(parts, create: false);
    if (current == null ||
        !_samePath(
          await current.resolveSymbolicLinks(),
          expectedCanonicalParent,
        )) {
      throw _unsafeParent();
    }
  }
}

String _join(String parent, String child) =>
    '$parent${Platform.pathSeparator}$child';

String _lockKey(String path) => Platform.isWindows ? path.toLowerCase() : path;

bool _samePath(String first, String second) =>
    _lockKey(first.replaceAll(RegExp(r'[\\/]+$'), '')) ==
    _lockKey(second.replaceAll(RegExp(r'[\\/]+$'), ''));

bool _withinRoot(String root, String candidate) {
  final normalizedRoot = _lockKey(root.replaceAll('\\', '/'));
  final normalizedCandidate = _lockKey(candidate.replaceAll('\\', '/'));
  return normalizedCandidate == normalizedRoot ||
      normalizedCandidate.startsWith('$normalizedRoot/');
}

FileSystemException _unsafeFile() =>
    const FileSystemException('Unsafe workspace file target');
FileSystemException _unsafeParent() =>
    const FileSystemException('Unsafe workspace parent');

// Dart has no portable openat/O_NOFOLLOW API. The process-wide per-root lock
// closes in-process races, and every component, parent, temporary, and target
// is revalidated immediately around I/O. A hostile external process can still
// substitute an entry in the final check-to-operation instruction window.
