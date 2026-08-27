import 'dart:io';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:synchronized/synchronized.dart';

import '../data/artifact_store.dart';
import '../data/local_artifact_files.dart';
import '../domain/artifact.dart';
import 'artifact_policy.dart';
import 'markdown_docx_converter.dart';

part 'artifacts_controller.g.dart';

@Riverpod(keepAlive: true)
class ArtifactsController extends _$ArtifactsController {
  ArtifactsController({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Lock _creationLock = Lock();
  int _lastAllocatedMicros = -1;

  ArtifactStore get _store => ref.read(artifactStoreProvider);
  LocalArtifactFiles get _files => ref.read(localArtifactFilesProvider);
  MarkdownDocxConverter get _docxConverter => const MarkdownDocxConverter();

  @override
  List<Artifact> build() => _store.loadAll();

  Future<Artifact> create({required String title, required String content}) =>
      _creationLock.synchronized(() async {
        ArtifactPolicy.validateDocument(title, content);
        final stored = _store.loadAll();
        ArtifactPolicy.validateQuotas(
          documentCount: stored.length + 1,
          totalBytes: _totalBytes(stored) + ArtifactPolicy.bytesOf(content),
        );
        final now = _clock();
        final id = await _allocateId(now);
        final artifact = Artifact(
          id: id,
          title: title.trim(),
          content: content,
          createdAt: now,
          updatedAt: now,
        );
        var markdownCreated = false;
        var metadataCreated = false;
        try {
          await _files.write(artifact.id, artifact.content);
          markdownCreated = true;
          await _store.save(artifact);
          metadataCreated = true;
          state = _store.loadAll();
          return artifact;
        } catch (error, stackTrace) {
          metadataCreated = metadataCreated || _store.contains(artifact.id);
          markdownCreated =
              markdownCreated ||
              await _files.exists(artifact.id, extension: 'md');
          if (metadataCreated) await _store.delete(artifact.id);
          if (markdownCreated) await _files.delete(artifact.id);
          state = _store.loadAll();
          Error.throwWithStackTrace(error, stackTrace);
        }
      });

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
  Future<CreatedDocxArtifact> createDocxArtifact({
    required String title,
    required String markdown,
  }) => _creationLock.synchronized(() async {
    ArtifactPolicy.validateDocument(title, markdown);
    final bytes = _docxConverter.generate(
      title: title.trim(),
      markdown: markdown,
    );
    final stored = _store.loadAll();
    ArtifactPolicy.validateQuotas(
      documentCount: stored.length + 1,
      totalBytes: _totalBytes(stored) + ArtifactPolicy.bytesOf(markdown),
    );
    final now = _clock();
    final id = await _allocateId(now);
    final artifact = Artifact(
      id: id,
      title: title.trim(),
      content: markdown,
      createdAt: now,
      updatedAt: now,
    );
    var metadataCreated = false;
    var markdownCreated = false;
    var docxCreated = false;
    try {
      await _files.write(artifact.id, markdown);
      markdownCreated = true;
      await _files.writeBytes(artifact.id, bytes, extension: 'docx');
      docxCreated = true;
      await _store.save(artifact);
      metadataCreated = true;
      state = _store.loadAll();
      return CreatedDocxArtifact(artifact: artifact, docxBytes: bytes);
    } catch (error, stackTrace) {
      final cleanupFailures = <String>[];
      metadataCreated = metadataCreated || _store.contains(artifact.id);
      markdownCreated =
          markdownCreated || await _files.exists(artifact.id, extension: 'md');
      docxCreated =
          docxCreated || await _files.exists(artifact.id, extension: 'docx');
      if (metadataCreated) {
        try {
          await _store.delete(artifact.id);
        } catch (_) {
          cleanupFailures.add('metadata_delete_failed');
        }
      }
      if (markdownCreated || docxCreated) {
        try {
          await _files.delete(artifact.id);
        } catch (_) {
          cleanupFailures.add('file_delete_failed');
        }
      }

      var metadataAbsent = false;
      var markdownAbsent = false;
      var docxAbsent = false;
      try {
        metadataAbsent = !_store.contains(artifact.id);
      } catch (_) {
        cleanupFailures.add('metadata_verification_failed');
      }
      try {
        markdownAbsent = !await _files.exists(artifact.id, extension: 'md');
      } catch (_) {
        cleanupFailures.add('markdown_verification_failed');
      }
      try {
        docxAbsent = !await _files.exists(artifact.id, extension: 'docx');
      } catch (_) {
        cleanupFailures.add('docx_verification_failed');
      }

      try {
        state = _store.loadAll();
      } catch (_) {
        cleanupFailures.add('state_reload_failed');
      }
      if (cleanupFailures.isNotEmpty ||
          !metadataAbsent ||
          !markdownAbsent ||
          !docxAbsent) {
        throw ArtifactRollbackException(
          metadataAbsent: metadataAbsent,
          markdownAbsent: markdownAbsent,
          docxAbsent: docxAbsent,
          cleanupHadErrors: cleanupFailures.isNotEmpty,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  });

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

  Future<String> _allocateId(DateTime now) async {
    var candidateMicros = now.microsecondsSinceEpoch;
    if (candidateMicros <= _lastAllocatedMicros) {
      candidateMicros = _lastAllocatedMicros + 1;
    }
    while (true) {
      final id = '$candidateMicros-artifact';
      final collides =
          _store.contains(id) ||
          await _files.exists(id, extension: 'md') ||
          await _files.exists(id, extension: 'docx');
      if (!collides) {
        _lastAllocatedMicros = candidateMicros;
        return id;
      }
      candidateMicros++;
    }
  }
}

class ArtifactRollbackException implements Exception {
  const ArtifactRollbackException({
    required this.metadataAbsent,
    required this.markdownAbsent,
    required this.docxAbsent,
    required this.cleanupHadErrors,
  });

  final bool metadataAbsent;
  final bool markdownAbsent;
  final bool docxAbsent;
  final bool cleanupHadErrors;

  @override
  String toString() => 'Artifact rollback incomplete';
}

class CreatedDocxArtifact {
  const CreatedDocxArtifact({required this.artifact, required this.docxBytes});

  final Artifact artifact;
  final List<int> docxBytes;
}
