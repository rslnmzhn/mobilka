import 'dart:io';

import 'memory_file_store_contracts.dart';

class PathBinaryPairWriter {
  const PathBinaryPairWriter({
    required this.resolveParent,
    required this.revalidateParent,
    required this.targetType,
    required this.write,
    required this.samePath,
  });

  final Future<String?> Function(List<String> parts) resolveParent;
  final Future<void> Function(List<String> parts, String parent)
  revalidateParent;
  final Future<FileSystemEntityType> Function(String parent, String leaf)
  targetType;
  final Future<void> Function(List<String> parts, WorkspaceBinaryFile payload)
  write;
  final bool Function(String first, String second) samePath;

  Future<WorkspacePairWriteResult> run(
    List<String> firstParts,
    WorkspaceBinaryFile first,
    List<String> secondParts,
    WorkspaceBinaryFile second,
  ) async {
    var state = const _PairState();
    try {
      final parent = await _sharedParent(firstParts, secondParts);
      final collision = await _hasCollision(parent, firstParts, secondParts);
      if (collision) return _collision;
      await revalidateParent(firstParts, parent);
      state = await _writeOne(state, firstParts, first);
      state = await _writeOne(state, secondParts, second);
      return state.result;
    } on _PairState catch (failed) {
      return failed.failure;
    } catch (_) {
      return state.failure;
    }
  }

  Future<String> _sharedParent(
    List<String> firstParts,
    List<String> secondParts,
  ) async {
    final first = await resolveParent(firstParts);
    final second = await resolveParent(secondParts);
    if (first == null || second == null || !samePath(first, second)) {
      throw const FileSystemException('Unsafe workspace parent');
    }
    await revalidateParent(firstParts, first);
    return first;
  }

  Future<bool> _hasCollision(
    String parent,
    List<String> first,
    List<String> second,
  ) async {
    for (final parts in [first, second]) {
      final type = await targetType(parent, parts.last);
      if (type == FileSystemEntityType.file) return true;
      if (type != FileSystemEntityType.notFound) {
        throw const FileSystemException('Unsafe workspace file target');
      }
    }
    return false;
  }

  Future<_PairState> _writeOne(
    _PairState state,
    List<String> parts,
    WorkspaceBinaryFile payload,
  ) async {
    if (await resolveParent(parts) == null) return state;
    final attempted = state.copyWith(writeAttempted: true);
    try {
      await write(parts, payload);
    } catch (_) {
      throw attempted;
    }
    return state.firstWritten
        ? const _PairState(firstWritten: true, secondWritten: true)
        : const _PairState(firstWritten: true);
  }

  static const _collision = WorkspacePairWriteResult(
    firstStatus: WorkspaceSiblingWriteStatus.collision,
    secondStatus: WorkspaceSiblingWriteStatus.collision,
  );
}

class _PairState implements Exception {
  const _PairState({
    this.firstWritten = false,
    this.secondWritten = false,
    this.writeAttempted = false,
  });

  final bool firstWritten;
  final bool secondWritten;
  final bool writeAttempted;

  _PairState copyWith({bool? writeAttempted}) => _PairState(
    firstWritten: firstWritten,
    secondWritten: secondWritten,
    writeAttempted: writeAttempted ?? this.writeAttempted,
  );

  WorkspacePairWriteResult get result => WorkspacePairWriteResult(
    firstStatus: firstWritten
        ? WorkspaceSiblingWriteStatus.verifiedWritten
        : WorkspaceSiblingWriteStatus.definitelyNotWritten,
    secondStatus: secondWritten
        ? WorkspaceSiblingWriteStatus.verifiedWritten
        : WorkspaceSiblingWriteStatus.definitelyNotWritten,
  );

  WorkspacePairWriteResult get failure {
    if (!writeAttempted) {
      return const WorkspacePairWriteResult(
        firstStatus: WorkspaceSiblingWriteStatus.indeterminate,
        secondStatus: WorkspaceSiblingWriteStatus.indeterminate,
      );
    }
    return WorkspacePairWriteResult(
      firstStatus: firstWritten
          ? WorkspaceSiblingWriteStatus.verifiedWritten
          : WorkspaceSiblingWriteStatus.indeterminate,
      secondStatus: firstWritten
          ? WorkspaceSiblingWriteStatus.indeterminate
          : WorkspaceSiblingWriteStatus.definitelyNotWritten,
    );
  }
}
