import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/artifacts/application/artifacts_controller.dart';
import 'package:mobilka/features/artifacts/data/artifact_share_bridge.dart';
import 'package:mobilka/features/artifacts/data/artifact_store.dart';
import 'package:mobilka/features/artifacts/data/local_artifact_files.dart';
import 'package:mobilka/features/artifacts/domain/artifact.dart';
import 'package:mobilka/features/artifacts/presentation/artifacts_bottom_sheet.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late Directory filesDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mobilka-artifacts');
    filesDir = Directory(p.join(tempDir.path, 'files'));
    await filesDir.create();
    Hive.init(p.join(tempDir.path, 'hive'));
    await Hive.openBox<dynamic>('artifacts');
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk('artifacts');
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  LocalArtifactFiles files() =>
      LocalArtifactFiles(baseDirectory: () => filesDir);

  List<Override> overrides(LocalArtifactFiles files, ArtifactShare share) => [
    localArtifactFilesProvider.overrideWithValue(files),
    artifactShareBridgeProvider.overrideWithValue(share),
  ];

  test('artifact round trips through storage json', () {
    final artifact = Artifact(
      id: '1-artifact',
      title: 'Notes',
      content: '# Hello',
      createdAt: DateTime.utc(2026, 8, 23),
      updatedAt: DateTime.utc(2026, 8, 23, 1),
    );

    final restored = Artifact.fromJson(artifact.toJson());

    expect(restored.id, artifact.id);
    expect(restored.title, artifact.title);
    expect(restored.content, artifact.content);
    expect(restored.createdAt, artifact.createdAt);
    expect(restored.updatedAt, artifact.updatedAt);
  });

  test('controller persists documents to hive and markdown files', () async {
    final container = ProviderContainer(
      overrides: overrides(files(), (_) async {}),
    );
    addTearDown(container.dispose);

    final created = await container
        .read(artifactsControllerProvider.notifier)
        .create(title: 'Notes', content: '# Hello');

    final stored = container.read(artifactsControllerProvider);
    expect(stored.single.title, 'Notes');

    final file = File(p.join(filesDir.path, '${created.id}.md'));
    expect(await file.readAsString(), '# Hello');

    await container
        .read(artifactsControllerProvider.notifier)
        .update(created, title: 'Notes 2', content: '# Updated');
    expect(container.read(artifactsControllerProvider).single.title, 'Notes 2');
    expect(await file.readAsString(), '# Updated');

    await container.read(artifactsControllerProvider.notifier).delete(created);
    expect(container.read(artifactsControllerProvider), isEmpty);
    expect(await file.exists(), isFalse);
  });

  testWidgets('documents tab creates edits and shares artifacts', (
    tester,
  ) async {
    final sharedPaths = <String>[];
    final created = <Artifact>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          artifactShareBridgeProvider.overrideWithValue(
            (path) async => sharedPaths.add(path),
          ),
          artifactsControllerProvider.overrideWith(
            () => _FakeController(created),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ArtifactsBottomSheet())),
      ),
    );

    await tester.tap(find.text('artifacts.documents'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('artifact-create')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('artifact-title-field')),
      'Meeting notes',
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('artifact-content-field')),
      '# Agenda',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('artifact-save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('artifact-documents')), findsOneWidget);
    expect(find.text('Meeting notes'), findsOneWidget);
    expect(created.single.content, '# Agenda');

    await tester.tap(find.byIcon(Icons.share_outlined));
    await tester.pumpAndSettle();

    expect(sharedPaths, hasLength(1));
    expect(sharedPaths.single.endsWith('.md'), isTrue);
  });
}

class _FakeController extends ArtifactsController {
  final List<Artifact> created;

  _FakeController(this.created);

  var _seq = 0;

  @override
  List<Artifact> build() => created;

  @override
  Future<Artifact> create({
    required String title,
    required String content,
  }) async {
    final artifact = Artifact(
      id: 'fake-${_seq++}',
      title: title,
      content: content,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    created.add(artifact);
    state = [...created];
    return artifact;
  }

  @override
  Future<void> update(
    Artifact artifact, {
    required String title,
    required String content,
  }) async {}

  @override
  Future<void> delete(Artifact artifact) async {}

  @override
  Future<String> shareablePath(Artifact artifact) async =>
      '/tmp/${artifact.id}.md';
}
