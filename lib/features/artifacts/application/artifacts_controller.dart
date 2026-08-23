import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../data/artifact_store.dart';
import '../data/local_artifact_files.dart';
import '../domain/artifact.dart';
import 'artifact_policy.dart';

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
    ArtifactPolicy.validateDocument(title, content);
    final stored = state;
    ArtifactPolicy.validateQuotas(
      documentCount: stored.length + 1,
      totalBytes: _totalBytes(stored) + ArtifactPolicy.bytesOf(content),
    );
    final now = DateTime.now();
    final artifact = Artifact(
      id: '${now.microsecondsSinceEpoch}-artifact',
      title: title.trim(),
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
    ArtifactPolicy.validateDocument(title, content);
    final others = state.where((item) => item.id != artifact.id);
    ArtifactPolicy.validateQuotas(
      documentCount: others.length + 1,
      totalBytes: _totalBytes(others) + ArtifactPolicy.bytesOf(content),
    );
    final updated = artifact.copyWith(title: title.trim(), content: content);
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

  int _totalBytes(Iterable<Artifact> artifacts) => artifacts.fold<int>(
    0,
    (sum, item) => sum + ArtifactPolicy.bytesOf(item.content),
  );
}
