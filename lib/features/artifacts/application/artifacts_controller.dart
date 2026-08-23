import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../data/artifact_store.dart';
import '../data/local_artifact_files.dart';
import '../domain/artifact.dart';

part 'artifacts_controller.g.dart';

@Riverpod(keepAlive: true)
class ArtifactsController extends _$ArtifactsController {
  ArtifactStore get _store => ref.read(artifactStoreProvider);
  LocalArtifactFiles get _files => ref.read(localArtifactFilesProvider);

  @override
  List<Artifact> build() => _store.loadAll();

  Future<Artifact> create({
    required String title,
    required String content,
  }) async {
    final now = DateTime.now();
    final artifact = Artifact(
      id: '${now.microsecondsSinceEpoch}-artifact',
      title: title,
      content: content,
      createdAt: now,
      updatedAt: now,
    );
    await _files.write(artifact.id, artifact.content);
    await _store.save(artifact);
    state = _store.loadAll();
    return artifact;
  }

  Future<void> update(
    Artifact artifact, {
    required String title,
    required String content,
  }) async {
    final updated = artifact.copyWith(title: title, content: content);
    await _files.write(updated.id, updated.content);
    await _store.save(updated);
    state = _store.loadAll();
  }

  Future<void> delete(Artifact artifact) async {
    await _files.delete(artifact.id);
    await _store.delete(artifact.id);
    state = _store.loadAll();
  }

  Future<String> shareablePath(Artifact artifact) async {
    final file = await _files.write(artifact.id, artifact.content);
    return file.path;
  }
}
