import 'dart:io';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../data/artifact_store.dart';
import '../data/local_artifact_files.dart';
import '../domain/artifact.dart';
import 'artifact_policy.dart';
import 'markdown_docx_converter.dart';

part 'artifacts_controller.g.dart';

@Riverpod(keepAlive: true)
class ArtifactsController extends _$ArtifactsController {
  ArtifactStore get _store => ref.read(artifactStoreProvider);
  LocalArtifactFiles get _files => ref.read(localArtifactFilesProvider);
  MarkdownDocxConverter get _docxConverter => const MarkdownDocxConverter();

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

  /// Creates a Markdown artifact together with a generated `.docx` sibling.
  ///
  /// Used by the `generate_docx` chat tool; quotas and document validation
  /// apply exactly as for manual creation.
  Future<Artifact> createDocxArtifact({
    required String title,
    required String markdown,
  }) async {
    ArtifactPolicy.validateDocument(title, markdown);
    final artifact = await create(title: title.trim(), content: markdown);
    await exportDocx(artifact);
    return artifact;
  }

  /// Regenerates the `.docx` representation for [artifact] and returns it.
  Future<File> exportDocx(Artifact artifact) async {
    final bytes = _docxConverter.generate(
      title: artifact.title,
      markdown: artifact.content,
    );
    return _files.writeBytes(artifact.id, bytes, extension: 'docx');
  }

  int _totalBytes(Iterable<Artifact> artifacts) => artifacts.fold<int>(
    0,
    (sum, item) => sum + ArtifactPolicy.bytesOf(item.content),
  );
}
