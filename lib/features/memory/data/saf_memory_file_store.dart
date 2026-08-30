import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:synchronized/synchronized.dart';

import 'memory_file_store_contracts.dart';
import 'saf_binary_artifact_pair_writer.dart';
import 'saf_memory_access.dart';

part 'saf_persona_tree_access.dart';

class SafMemoryFileStore
    implements
        MemoryFileStore,
        SubPathMemoryFileBoundary,
        CompareWriteSubPathMemoryFileBoundary,
        SkillCandidateCommitBoundary,
        ExclusiveSkillCreateBoundary,
        BinarySubPathMemoryFileBoundary {
  SafMemoryFileStore(this.directoryUri, this._access);

  final String directoryUri;
  final SafMemoryAccess _access;
  @override
  bool get supportsExclusiveCreateAndVerifiedReadback => false;
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
    return action(_SafMemoryFileTransaction(this, documents));
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
  Future<WorkspaceCompareWriteResult> compareWriteSubPath(
    String relativePath,
    String? expectedContent,
    String content,
  ) async {
    final parts = MemoryFileValidation.subPath(relativePath);
    if (parts == null) return WorkspaceCompareWriteResult.failed;
    return _lock.synchronized(() async {
      final parent = await _resolveOrCreateDirectories(
        parts.sublist(0, parts.length - 1),
      );
      final leaf = await _resolveExactChild(
        parent,
        parts.last,
        expectedDirectory: false,
        allowMissing: true,
      );
      final current = leaf == null
          ? null
          : MemoryFileCodec.decode(await _access.read(leaf.uri));
      if (current != expectedContent) {
        return WorkspaceCompareWriteResult.conflict;
      }
      await _access.write(
        parent,
        parts.last,
        MemoryFileCodec.encode(content),
        overwrite: expectedContent != null,
      );
      return WorkspaceCompareWriteResult.written;
    });
  }

  @override
  Future<SkillCommitResult> commitSkillCandidate({
    required String name,
    required String content,
    required String? expectedHash,
    required int maxCount,
    required int maxTotalBytes,
  }) async {
    if (!MemoryFileValidation.isSafeSkillFileName(name)) {
      return SkillCommitResult.failed;
    }
    return _lock.synchronized(
      () => _commitSkillLocked(
        name: name,
        content: content,
        expectedHash: expectedHash,
        maxCount: maxCount,
        maxTotalBytes: maxTotalBytes,
      ),
    );
  }

  Future<SkillCommitResult> _commitSkillLocked({
    required String name,
    required String content,
    required String? expectedHash,
    required int maxCount,
    required int maxTotalBytes,
  }) async {
    final parent = await _resolveOrCreateDirectories(const ['skills']);
    final safe = (await _access.list(parent))
        .where((item) => MemoryFileValidation.isSafeSkillFileName(item.name))
        .toList();
    if (safe.any((item) => item.isDirectory)) {
      return SkillCommitResult.unsupported;
    }
    final matches = safe.where((item) => item.name == name).toList();
    if (matches.length > 1) return SkillCommitResult.unsupported;
    final current = matches.singleOrNull;
    final bytes = current == null ? null : await _access.read(current.uri);
    if ((bytes == null ? null : sha256.convert(bytes).toString()) !=
        expectedHash) {
      return SkillCommitResult.conflict;
    }
    final incoming = utf8.encode(content);
    final total = await _skillBytes(safe, name, incoming.length);
    if ((current == null && safe.length >= maxCount) || total > maxTotalBytes) {
      return SkillCommitResult.quotaExceeded;
    }
    return _writeAndVerifySkill(parent, name, incoming, current);
  }

  Future<SkillCommitResult> _writeAndVerifySkill(
    String parent,
    String name,
    Uint8List incoming,
    SafMemoryDocument? current,
  ) async {
    await _access.write(parent, name, incoming, overwrite: current != null);
    final verified = await _resolveExactChild(
      parent,
      name,
      expectedDirectory: false,
      allowMissing: false,
    );
    if (verified == null || (current != null && verified.uri != current.uri)) {
      return SkillCommitResult.unsupported;
    }
    return sha256.convert(await _access.read(verified.uri)) ==
            sha256.convert(incoming)
        ? SkillCommitResult.written
        : SkillCommitResult.failed;
  }

  Future<int> _skillBytes(
    List<SafMemoryDocument> safe,
    String name,
    int incomingBytes,
  ) async {
    var total = incomingBytes;
    for (final item in safe.where((item) => item.name != name)) {
      total += (await _access.read(item.uri)).length;
    }
    return total;
  }

  @override
  Future<WorkspacePairWriteResult> writeBinaryPair(
    WorkspaceBinaryFile first,
    WorkspaceBinaryFile second,
  ) async {
    return _lock.synchronized(
      () => SafBinaryArtifactPairWriter(
        access: _access,
        resolveDirectories: _resolveOrCreateDirectories,
        resolveChild: _resolveExactChild,
      ).writePair(first, second),
    );
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
