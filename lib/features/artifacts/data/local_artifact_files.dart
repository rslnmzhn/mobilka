import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/artifact_file_name.dart';

/// Persists artifact payloads as human-readable `.md` files.
///
/// File names are always derived from internally generated artifact IDs and
/// revalidated through [ArtifactFileName] on every operation, so user-supplied
/// titles never reach the file system and traversal is impossible even for a
/// corrupted ID (filename validation/traversal policy: roadmap item 40).
class LocalArtifactFiles {
  LocalArtifactFiles({Directory? Function()? baseDirectory})
    : _baseDirectory = baseDirectory;

  final Directory? Function()? _baseDirectory;

  Future<Directory> _resolveBase() async {
    final override = _baseDirectory?.call();
    if (override != null) return override;
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'artifacts'));
  }

  Future<File> fileFor(String artifactId) async {
    final fileName = ArtifactFileName.fromId(artifactId);
    final base = await _resolveBase();
    await base.create(recursive: true);
    return File(p.join(base.path, fileName.value));
  }

  /// Writes content atomically via a temp file plus rename.
  Future<File> write(String artifactId, String content) async {
    final target = await fileFor(artifactId);
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

  Future<void> delete(String artifactId) async {
    final target = await fileFor(artifactId);
    if (await target.exists()) {
      await target.delete();
    }
  }
}
