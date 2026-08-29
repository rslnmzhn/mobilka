import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'memory_file_store_contracts.dart';

typedef PathSkillParentResolver = Future<Directory?> Function();
typedef PathSkillAtomicUpdate =
    Future<void> Function(File target, List<int> bytes);

/// Performs a skill quota/CAS commit while its caller owns the workspace root
/// lock. This helper deliberately owns no lock and cannot be invoked without a
/// lock-owned parent resolver and atomic-update callback from the path store.
final class PathSkillCommit {
  const PathSkillCommit({
    required this.resolveParent,
    required this.atomicUpdate,
  });

  final PathSkillParentResolver resolveParent;
  final PathSkillAtomicUpdate atomicUpdate;

  Future<SkillCommitResult> run({
    required String name,
    required String content,
    required String? expectedHash,
    required int maxCount,
    required int maxTotalBytes,
  }) async {
    if (!MemoryFileValidation.isSafeSkillFileName(name)) {
      return SkillCommitResult.failed;
    }
    final parent = await resolveParent();
    if (parent == null) return SkillCommitResult.failed;
    final files = await _safeFiles(parent);
    if (files == null) return SkillCommitResult.failed;
    final target = File('${parent.path}${Platform.pathSeparator}$name');
    final targetType = await FileSystemEntity.type(
      target.path,
      followLinks: false,
    );
    if (targetType != FileSystemEntityType.file &&
        targetType != FileSystemEntityType.notFound) {
      return SkillCommitResult.failed;
    }
    if (await _hash(target, targetType) != expectedHash) {
      return SkillCommitResult.conflict;
    }
    final incoming = utf8.encode(content);
    if (await _exceedsQuota(
      files: files,
      target: target,
      targetMissing: targetType == FileSystemEntityType.notFound,
      incomingBytes: incoming.length,
      maxCount: maxCount,
      maxTotalBytes: maxTotalBytes,
    )) {
      return SkillCommitResult.quotaExceeded;
    }
    final result = targetType == FileSystemEntityType.notFound
        ? await _createExclusive(target, incoming)
        : await _update(target, incoming, expectedHash);
    if (result != SkillCommitResult.written) return result;
    return await _hash(target, FileSystemEntityType.file) == _digest(incoming)
        ? SkillCommitResult.written
        : SkillCommitResult.failed;
  }

  Future<List<File>?> _safeFiles(Directory parent) async {
    final files = <File>[];
    await for (final entry in parent.list(followLinks: false)) {
      final name = entry.uri.pathSegments.last;
      if (!MemoryFileValidation.isSafeSkillFileName(name)) continue;
      if (await FileSystemEntity.type(entry.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      files.add(File(entry.path));
    }
    return files;
  }

  Future<bool> _exceedsQuota({
    required List<File> files,
    required File target,
    required bool targetMissing,
    required int incomingBytes,
    required int maxCount,
    required int maxTotalBytes,
  }) async {
    if (targetMissing && files.length >= maxCount) return true;
    var total = incomingBytes;
    for (final file in files) {
      if (_samePath(file.path, target.path)) continue;
      total += await file.length();
      if (total > maxTotalBytes) return true;
    }
    return total > maxTotalBytes;
  }

  Future<SkillCommitResult> _createExclusive(
    File target,
    List<int> incoming,
  ) async {
    RandomAccessFile? handle;
    try {
      await target.create(exclusive: true);
      handle = await target.open(mode: FileMode.writeOnly);
      await handle.writeFrom(incoming);
      await handle.flush();
      return SkillCommitResult.written;
    } on FileSystemException {
      return SkillCommitResult.conflict;
    } finally {
      await handle?.close();
    }
  }

  Future<SkillCommitResult> _update(
    File target,
    List<int> incoming,
    String? expectedHash,
  ) async {
    if (await _hash(target, FileSystemEntityType.file) != expectedHash) {
      return SkillCommitResult.conflict;
    }
    await atomicUpdate(target, incoming);
    return SkillCommitResult.written;
  }

  Future<String?> _hash(File file, FileSystemEntityType type) async =>
      type == FileSystemEntityType.file
      ? _digest(await file.readAsBytes())
      : null;

  String _digest(List<int> bytes) => sha256.convert(bytes).toString();

  bool _samePath(String first, String second) {
    String normalize(String value) {
      final trimmed = value.replaceAll(RegExp(r'[\\/]+$'), '');
      return Platform.isWindows ? trimmed.toLowerCase() : trimmed;
    }

    return normalize(first) == normalize(second);
  }
}
