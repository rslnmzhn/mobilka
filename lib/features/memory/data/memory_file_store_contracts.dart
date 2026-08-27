import 'dart:convert';
import 'dart:typed_data';

abstract interface class MemoryFileBoundary {
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  );

  Future<String> read(String fileName);
  Future<void> write(String fileName, String content);
  Future<void> delete(String fileName);
}

abstract interface class MemoryFileTransaction {
  Future<String> read(String fileName);
  Future<void> write(String fileName, String content);
}

abstract interface class MissingAwareMemoryFileTransaction {
  Future<String?> readIfExists(String fileName);
}

abstract interface class DeletingMemoryFileTransaction {
  Future<void> delete(String fileName);
}

abstract interface class MemoryFileStore implements MemoryFileBoundary {
  Future<void> createIfMissing(String fileName, String content);
}

/// Capability interface for the exact skills and session workspace layouts.
abstract interface class SubPathMemoryFileBoundary {
  Future<String?> readSubPath(String relativePath);
  Future<bool> writeSubPath(String relativePath, String content);
  Future<List<String>> listSubPath(String relativeDirectory);
}

const maxArtifactMarkdownBytes = 2 * 1024 * 1024;
const maxArtifactDocxBytes = 10 * 1024 * 1024;

final class WorkspaceBinaryFile {
  const WorkspaceBinaryFile({
    required this.relativePath,
    required this.bytes,
    required this.mimeType,
    required this.maxBytes,
  });

  final String relativePath;
  final Uint8List bytes;
  final String mimeType;
  final int maxBytes;

  void validate() {
    if (MemoryFileValidation.subPath(relativePath) == null) {
      throw const FormatException('Invalid workspace artifact path');
    }
    if (bytes.length > maxBytes) {
      throw const FormatException('Workspace artifact exceeds the size limit');
    }
  }
}

enum WorkspaceSiblingWriteStatus {
  verifiedWritten,
  definitelyNotWritten,
  collision,
  indeterminate,
}

final class WorkspacePairWriteResult {
  const WorkspacePairWriteResult({
    required this.firstStatus,
    required this.secondStatus,
  });

  final WorkspaceSiblingWriteStatus firstStatus;
  final WorkspaceSiblingWriteStatus secondStatus;

  bool get firstWritten =>
      firstStatus == WorkspaceSiblingWriteStatus.verifiedWritten;
  bool get secondWritten =>
      secondStatus == WorkspaceSiblingWriteStatus.verifiedWritten;
  bool get complete => firstWritten && secondWritten;
  bool get hasCollision =>
      firstStatus == WorkspaceSiblingWriteStatus.collision ||
      secondStatus == WorkspaceSiblingWriteStatus.collision;
  bool get hasIndeterminate =>
      firstStatus == WorkspaceSiblingWriteStatus.indeterminate ||
      secondStatus == WorkspaceSiblingWriteStatus.indeterminate;
}

/// Bounded binary pair capability. The pair is serialized by one store/root
/// lock, but is not claimed to be atomic across two filesystem or SAF writes.
abstract interface class BinarySubPathMemoryFileBoundary {
  Future<WorkspacePairWriteResult> writeBinaryPair(
    WorkspaceBinaryFile first,
    WorkspaceBinaryFile second,
  );
}

const maxMemoryFileBytes = 1024 * 1024;

final class MemoryFileCodec {
  const MemoryFileCodec._();

  static Uint8List encode(String content) {
    final bytes = utf8.encode(content);
    if (bytes.length > maxMemoryFileBytes) {
      throw const FormatException('Memory file exceeds the size limit');
    }
    return Uint8List.fromList(bytes);
  }

  static String decode(List<int> bytes) {
    if (bytes.length > maxMemoryFileBytes) {
      throw const FormatException('Memory file exceeds the size limit');
    }
    return utf8.decode(bytes, allowMalformed: false);
  }
}

final class MemoryFileValidation {
  const MemoryFileValidation._();

  static final RegExp _sessionKey = RegExp(
    r'^[a-zа-яё0-9_-]+$',
    caseSensitive: false,
  );
  static final RegExp _artifactFile = RegExp(
    r'^[a-z0-9][a-z0-9_.-]*$',
    caseSensitive: false,
  );
  static final RegExp _memoryFile = RegExp(
    r'^[a-z0-9][a-z0-9_.-]*\.(md|yaml|bak)$',
  );
  static final RegExp _skillFile = RegExp(r'^[a-z0-9][a-z0-9-]{0,63}\.md$');

  static void validateFileName(String fileName) {
    if (!_memoryFile.hasMatch(fileName) || fileName.contains('..')) {
      throw const FormatException('Invalid memory file name');
    }
  }

  static bool isSafeSkillFileName(String name) => _skillFile.hasMatch(name);

  /// Accepts only `skills/{name}.md`, `sessions/{key}/session.md`, and
  /// `sessions/{key}/artifacts/{file}`.
  static List<String>? subPath(String relativePath) {
    final normalized = relativePath.replaceAll('\\', '/');
    if (normalized.startsWith('/') || normalized.contains('..')) return null;
    final parts = normalized.split('/');
    if (parts.any((part) => part.isEmpty)) return null;
    if (parts.length == 2 &&
        parts.first == 'skills' &&
        isSafeSkillFileName(parts.last)) {
      return parts;
    }
    if ((parts.length != 3 && parts.length != 4) ||
        parts.first != 'sessions' ||
        !_sessionKey.hasMatch(parts[1])) {
      return null;
    }
    if (parts.length == 3) {
      return parts.last == 'session.md' ? parts : null;
    }
    return parts[2] == 'artifacts' &&
            _artifactFile.hasMatch(parts.last) &&
            !parts.last.contains('..')
        ? parts
        : null;
  }

  static List<String>? listSubPath(String relativePath) =>
      relativePath.replaceAll('\\', '/') == 'skills' ? const ['skills'] : null;
}
