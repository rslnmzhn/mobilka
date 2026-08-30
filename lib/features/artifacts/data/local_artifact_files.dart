import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

import '../domain/artifact_file_name.dart';

/// Persists artifact payloads as human-readable files (`.md` documents and
/// generated `.docx` exports).
///
/// File names are always derived from internally generated artifact IDs and
/// revalidated through [ArtifactFileName] on every operation, so user-supplied
/// titles never reach the file system and traversal is impossible even for a
/// corrupted ID (filename validation/traversal policy: roadmap item 40).
class LocalArtifactFiles {
  LocalArtifactFiles({Directory? Function()? baseDirectory})
    : _baseDirectory = baseDirectory;

  final Directory? Function()? _baseDirectory;
  final Lock _operationLock = Lock();

  Future<Directory> _resolveBase() async {
    final override = _baseDirectory?.call();
    if (override != null) return override;
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'artifacts'));
  }

  Future<File> fileFor(String artifactId, {String extension = 'md'}) async {
    final fileName = ArtifactFileName.fromId(artifactId, extension: extension);
    final base = await _resolveBase();
    await base.create(recursive: true);
    return File(p.join(base.path, fileName.value));
  }

  /// Writes text content atomically via a temp file plus rename.
  Future<File> write(
    String artifactId,
    String content, {
    String extension = 'md',
  }) async {
    final target = await fileFor(artifactId, extension: extension);
    final temp = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temp.writeAsString(content, flush: true);
    try {
      return await temp.rename(target.path);
    } on FileSystemException {
      await temp.delete();
      rethrow;
    }
  }

  /// Writes binary payloads (e.g. generated `.docx`) atomically.
  Future<File> writeBytes(
    String artifactId,
    List<int> bytes, {
    String extension = 'md',
  }) async {
    final target = await fileFor(artifactId, extension: extension);
    final temp = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temp.writeAsBytes(bytes, flush: true);
    try {
      return await temp.rename(target.path);
    } on FileSystemException {
      await temp.delete();
      rethrow;
    }
  }

  Future<void> delete(String artifactId) async {
    // Remove every known representation of the artifact.
    for (final extension in const ['md', 'docx']) {
      final target = await fileFor(artifactId, extension: extension);
      if (await target.exists()) {
        await target.delete();
      }
    }
  }

  Future<void> deleteRepresentation(
    String artifactId, {
    required String extension,
  }) async {
    final target = await fileFor(artifactId, extension: extension);
    if (await FileSystemEntity.type(target.path, followLinks: false) ==
        FileSystemEntityType.file) {
      await target.delete();
    }
  }

  Future<bool> exists(String artifactId, {required String extension}) async {
    final target = await fileFor(artifactId, extension: extension);
    return target.exists();
  }

  /// Reads representation metadata without creating, copying, or discovering
  /// files outside the app-private artifact directory.
  Future<FileStat?> stat(String artifactId, {required String extension}) async {
    try {
      final fileName = ArtifactFileName.fromId(
        artifactId,
        extension: extension,
      );
      final base = await _resolveBase();
      final basePath = p.normalize(p.absolute(base.path));
      final targetPath = p.normalize(p.join(basePath, fileName.value));
      if (!p.isWithin(basePath, targetPath)) return null;
      final type = await FileSystemEntity.type(targetPath, followLinks: false);
      if (type != FileSystemEntityType.file) return null;

      final canonicalBase = await base.resolveSymbolicLinks();
      final canonicalTarget = await File(targetPath).resolveSymbolicLinks();
      if (!p.isWithin(canonicalBase, canonicalTarget)) return null;
      if (await FileSystemEntity.type(targetPath, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final stat = await File(targetPath).stat();
      if (stat.type != FileSystemEntityType.file) return null;
      final finalCanonicalTarget = await File(
        targetPath,
      ).resolveSymbolicLinks();
      if (finalCanonicalTarget != canonicalTarget ||
          !p.isWithin(canonicalBase, finalCanonicalTarget) ||
          await FileSystemEntity.type(targetPath, followLinks: false) !=
              FileSystemEntityType.file) {
        return null;
      }
      return stat;
    } on Object {
      return null;
    }
  }

  /// Resolves an existing regular file without creating directories. The
  /// returned identity must be rechecked immediately before native opening.
  Future<VerifiedArtifactFile?> resolveVerified(
    String artifactId, {
    required String extension,
  }) async {
    try {
      final name = ArtifactFileName.fromId(artifactId, extension: extension);
      final base = await _resolveBase();
      if (await FileSystemEntity.type(base.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return null;
      }
      final basePath = p.normalize(p.absolute(base.path));
      final targetPath = p.normalize(p.join(basePath, name.value));
      if (!p.isWithin(basePath, targetPath)) return null;
      final canonicalBase = await base.resolveSymbolicLinks();
      if (await FileSystemEntity.type(targetPath, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final canonicalTarget = await File(targetPath).resolveSymbolicLinks();
      if (!p.isWithin(canonicalBase, canonicalTarget)) return null;
      return VerifiedArtifactFile._(
        path: targetPath,
        canonicalBase: canonicalBase,
        canonicalPath: canonicalTarget,
      );
    } on Object {
      return null;
    }
  }

  Future<String?> recheckVerified(VerifiedArtifactFile verified) async {
    try {
      if (await FileSystemEntity.type(verified.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final canonical = await File(verified.path).resolveSymbolicLinks();
      final stat = await File(verified.path).stat();
      if (canonical != verified.canonicalPath ||
          !p.isWithin(verified.canonicalBase, canonical) ||
          stat.type != FileSystemEntityType.file) {
        return null;
      }
      return verified.path;
    } on Object {
      return null;
    }
  }

  /// Performs the final identity check and native handoff as one serialized
  /// app operation. A same-user process may still replace a path after OS
  /// handoff; Dart offers no portable descriptor-based native viewer API.
  Future<T?> withVerifiedFileForOpen<T>(
    String artifactId, {
    required String extension,
    required Future<T> Function(String path) callback,
  }) => _operationLock.synchronized(() async {
    final verified = await resolveVerified(artifactId, extension: extension);
    if (verified == null) return null;
    final path = await recheckVerified(verified);
    if (path == null) return null;
    return callback(path);
  });
}

class VerifiedArtifactFile {
  const VerifiedArtifactFile._({
    required this.path,
    required this.canonicalBase,
    required this.canonicalPath,
  });

  final String path;
  final String canonicalBase;
  final String canonicalPath;
}
