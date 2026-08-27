import 'dart:typed_data';

import 'memory_file_store_contracts.dart';
import 'saf_memory_access.dart';

typedef SafDirectoryResolver = Future<String> Function(List<String> parts);
typedef SafChildResolver =
    Future<SafMemoryDocument?> Function(
      String parentUri,
      String name, {
      required bool expectedDirectory,
      required bool allowMissing,
    });

final class SafBinaryArtifactPairWriter {
  const SafBinaryArtifactPairWriter({
    required SafMemoryAccess access,
    required SafDirectoryResolver resolveDirectories,
    required SafChildResolver resolveChild,
  }) : _access = access,
       _resolveDirectories = resolveDirectories,
       _resolveChild = resolveChild;

  final SafMemoryAccess _access;
  final SafDirectoryResolver _resolveDirectories;
  final SafChildResolver _resolveChild;

  Future<WorkspacePairWriteResult> writePair(
    WorkspaceBinaryFile first,
    WorkspaceBinaryFile second,
  ) async {
    first.validate();
    second.validate();
    if (_access is! SafMemoryBinaryAccess) {
      throw StateError('SAF binary workspace writes are unavailable');
    }
    final binaryAccess = _access as SafMemoryBinaryAccess;
    final firstParts = MemoryFileValidation.subPath(first.relativePath)!;
    final secondParts = MemoryFileValidation.subPath(second.relativePath)!;
    String parent;
    try {
      final firstParentParts = firstParts.sublist(0, firstParts.length - 1);
      final secondParentParts = secondParts.sublist(0, secondParts.length - 1);
      if (!_sameParts(firstParentParts, secondParentParts)) {
        throw StateError('Workspace pair must use one parent');
      }
      parent = await _resolveDirectories(firstParentParts);
      final firstExisting = await _resolveChild(
        parent,
        firstParts.last,
        expectedDirectory: false,
        allowMissing: true,
      );
      final secondExisting = await _resolveChild(
        parent,
        secondParts.last,
        expectedDirectory: false,
        allowMissing: true,
      );
      if (firstExisting != null || secondExisting != null) {
        return const WorkspacePairWriteResult(
          firstStatus: WorkspaceSiblingWriteStatus.collision,
          secondStatus: WorkspaceSiblingWriteStatus.collision,
        );
      }
    } catch (_) {
      return const WorkspacePairWriteResult(
        firstStatus: WorkspaceSiblingWriteStatus.indeterminate,
        secondStatus: WorkspaceSiblingWriteStatus.indeterminate,
      );
    }
    final firstStatus = await _createVerified(
      binaryAccess,
      parent,
      firstParts.last,
      first,
    );
    if (firstStatus != WorkspaceSiblingWriteStatus.verifiedWritten) {
      return WorkspacePairWriteResult(
        firstStatus: firstStatus,
        secondStatus: WorkspaceSiblingWriteStatus.definitelyNotWritten,
      );
    }
    return WorkspacePairWriteResult(
      firstStatus: firstStatus,
      secondStatus: await _createVerified(
        binaryAccess,
        parent,
        secondParts.last,
        second,
      ),
    );
  }

  Future<WorkspaceSiblingWriteStatus> _createVerified(
    SafMemoryBinaryAccess binaryAccess,
    String parent,
    String name,
    WorkspaceBinaryFile payload,
  ) async {
    var writeAttempted = false;
    try {
      writeAttempted = true;
      final created = await binaryAccess.createBinary(
        parent,
        name,
        payload.bytes,
        mimeType: payload.mimeType,
        overwrite: false,
      );
      if (created.name != name || created.isDirectory) {
        throw StateError('SAF provider returned an invalid document');
      }
      final verified = await _resolveChild(
        parent,
        name,
        expectedDirectory: false,
        allowMissing: false,
      );
      if (verified!.uri != created.uri) {
        throw StateError('SAF provider returned an unverified document');
      }
      _verifyMime(created, payload.mimeType);
      _verifyMime(verified, payload.mimeType);
      await _verifyExactBytes(verified.uri, payload.bytes);
      return WorkspaceSiblingWriteStatus.verifiedWritten;
    } catch (_) {
      return writeAttempted
          ? WorkspaceSiblingWriteStatus.indeterminate
          : WorkspaceSiblingWriteStatus.definitelyNotWritten;
    }
  }

  bool _sameParts(List<String> first, List<String> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  Future<void> _verifyExactBytes(String documentUri, Uint8List expected) async {
    final actual = await _access.read(documentUri);
    if (actual.length != expected.length) {
      throw StateError('SAF provider stored unexpected document bytes');
    }
    for (var index = 0; index < expected.length; index++) {
      if (actual[index] != expected[index]) {
        throw StateError('SAF provider stored unexpected document bytes');
      }
    }
  }

  void _verifyMime(SafMemoryDocument document, String expected) {
    if (document.mimeType != expected) {
      throw StateError('Workspace document MIME type is unverifiable');
    }
  }
}
