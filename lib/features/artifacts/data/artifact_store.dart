import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/storage/app_boxes.dart';
import '../domain/artifact.dart';
import 'local_artifact_files.dart';

part 'artifact_store.g.dart';

@Riverpod(keepAlive: true)
LocalArtifactFiles localArtifactFiles(Ref ref) => LocalArtifactFiles();

/// Invalidates read-only projections of the authoritative app-private files.
final artifactRepresentationsRevisionProvider = StateProvider<int>((ref) => 0);

@Riverpod(keepAlive: true)
ArtifactStore artifactStore(Ref ref) => ArtifactStore();

class ArtifactStore {
  List<Artifact> loadAll() {
    final result = <Artifact>[];
    for (final key in artifactsBox.keys) {
      if (key is! String) continue;
      final artifact = loadById(key);
      if (artifact != null) result.add(artifact);
    }
    return result..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<void> save(Artifact artifact) =>
      artifactsBox.put(artifact.id, artifact.toJson());

  Future<void> delete(String id) => artifactsBox.delete(id);

  bool contains(String id) => artifactsBox.containsKey(id);

  /// Loads one record and rejects corrupt records whose payload ID does not
  /// exactly match the authoritative Hive key.
  Artifact? loadById(String id) {
    final raw = artifactsBox.get(id);
    if (raw is! Map) return null;
    try {
      final artifact = Artifact.fromJson(raw);
      return artifact.id == id ? artifact : null;
    } on Object {
      return null;
    }
  }
}
