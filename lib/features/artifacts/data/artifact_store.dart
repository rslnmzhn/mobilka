import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/storage/app_boxes.dart';
import '../domain/artifact.dart';
import 'local_artifact_files.dart';

part 'artifact_store.g.dart';

@Riverpod(keepAlive: true)
LocalArtifactFiles localArtifactFiles(Ref ref) => LocalArtifactFiles();

@Riverpod(keepAlive: true)
ArtifactStore artifactStore(Ref ref) => ArtifactStore();

class ArtifactStore {
  List<Artifact> loadAll() {
    return artifactsBox.values.whereType<Map>().map(Artifact.fromJson).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<void> save(Artifact artifact) =>
      artifactsBox.put(artifact.id, artifact.toJson());

  Future<void> delete(String id) => artifactsBox.delete(id);

  bool contains(String id) => artifactsBox.containsKey(id);
}
