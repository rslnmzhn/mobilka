import 'dart:io';

import 'package:synchronized/synchronized.dart';

abstract interface class MemoryFileStore {
  Future<String> read(String fileName);
  Future<void> write(String fileName, String content);
  Future<void> createIfMissing(String fileName, String content);
}

class PathMemoryFileStore implements MemoryFileStore {
  PathMemoryFileStore(this.directoryPath);

  final String directoryPath;
  static final Map<String, Lock> _directoryLocks = {};

  @override
  Future<String> read(String fileName) async {
    final target = await _target(fileName);
    return target.lock.synchronized(() => target.file.readAsString());
  }

  @override
  Future<void> write(String fileName, String content) async {
    final target = await _target(fileName);
    await target.lock.synchronized(() async {
      await _assertRegularOrMissing(target.file);
      await target.file.writeAsString(content, flush: true);
    });
  }

  @override
  Future<void> createIfMissing(String fileName, String content) async {
    final target = await _target(fileName);
    await target.lock.synchronized(() async {
      final type = await FileSystemEntity.type(
        target.file.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        await target.file.writeAsString(content, flush: true);
      } else if (type != FileSystemEntityType.file) {
        throw const FileSystemException('Unsafe memory file target');
      }
    });
  }

  Future<_LockedTarget> _target(String fileName) async {
    if (!_isSafeMarkdownName(fileName)) {
      throw const FormatException('Invalid memory file name');
    }
    final directory = Directory(directoryPath);
    final canonicalDirectory = await directory.resolveSymbolicLinks();
    final lock = _directoryLocks.putIfAbsent(canonicalDirectory, Lock.new);
    final file = File('$canonicalDirectory${Platform.pathSeparator}$fileName');
    return _LockedTarget(file, lock);
  }

  Future<void> _assertRegularOrMissing(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw const FileSystemException('Unsafe memory file target');
    }
  }
}

class _LockedTarget {
  const _LockedTarget(this.file, this.lock);
  final File file;
  final Lock lock;
}

bool _isSafeMarkdownName(String fileName) =>
    RegExp(r'^[a-z0-9][a-z0-9_-]*\.md$').hasMatch(fileName) &&
    !fileName.contains('..');
