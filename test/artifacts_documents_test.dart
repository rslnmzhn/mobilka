import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/core/storage/app_boxes.dart';
import 'package:mobilka/features/artifacts/application/artifact_policy.dart';
import 'package:mobilka/features/artifacts/application/artifacts_controller.dart';
import 'package:mobilka/features/artifacts/data/artifact_share_bridge.dart';
import 'package:mobilka/features/artifacts/data/artifact_store.dart';
import 'package:mobilka/features/artifacts/data/local_artifact_files.dart';
import 'package:mobilka/features/artifacts/domain/artifact.dart';
import 'package:mobilka/features/artifacts/domain/artifact_file_name.dart';
import 'package:mobilka/features/artifacts/presentation/artifacts_bottom_sheet.dart';
import 'package:mobilka/features/artifacts/presentation/document_editor_sheet.dart';
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

  group('artifact file names reject traversal', () {
    for (final invalid in [
      '',
      '../escape',
      'sub/dir',
      r'back\slash',
      '.hidden',
      '-leading-dash',
      'has space',
      'a${'x' * 64}',
    ]) {
      test('rejects ${invalid.isEmpty ? '<empty>' : '"$invalid"'}', () {
        expect(() => ArtifactFileName.fromId(invalid), throwsFormatException);
      });
    }

    test('accepts generated ids and appends md extension', () {
      expect(
        ArtifactFileName.fromId('1755900000000000-artifact').value,
        '1755900000000000-artifact.md',
      );
    });

    test('file layer refuses traversal ids without touching disk', () async {
      final fileStore = files();
      await expectLater(
        fileStore.write('../evil', 'nope'),
        throwsFormatException,
      );
      expect(filesDir.listSync().whereType<File>(), isEmpty);
    });
  });

  group('artifact policy', () {
    test('rejects empty and oversized titles', () {
      expect(
        () => ArtifactPolicy.validateDocument('   ', 'x'),
        throwsA(const ArtifactPolicyException('artifacts.errorTitleRequired')),
      );
      expect(
        () => ArtifactPolicy.validateDocument('a' * 121, 'x'),
        throwsA(const ArtifactPolicyException('artifacts.errorTitleTooLong')),
      );
    });

    test('rejects content beyond the byte cap', () {
      expect(
        () => ArtifactPolicy.validateDocument(
          'ok',
          'a' * (ArtifactPolicy.maxContentBytes + 1),
        ),
        throwsA(
          const ArtifactPolicyException('artifacts.errorContentTooLarge'),
        ),
      );
    });

    test('quota checks compare post-change aggregates', () {
      expect(
        () => ArtifactPolicy.validateQuotas(
          documentCount: ArtifactPolicy.maxDocuments + 1,
          totalBytes: 1,
        ),
        throwsA(const ArtifactPolicyException('artifacts.errorQuotaDocuments')),
      );
      expect(
        () => ArtifactPolicy.validateQuotas(
          documentCount: 1,
          totalBytes: ArtifactPolicy.maxTotalBytes + 1,
        ),
        throwsA(const ArtifactPolicyException('artifacts.errorQuotaStorage')),
      );
    });
  });

  test('controller persists documents to hive and markdown files', () async {
    final container = ProviderContainer(
      overrides: overrides(files(), (_, {mimeType}) async {}),
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

  test(
    'concurrent creations with the same clock reserve distinct IDs',
    () async {
      final fixedNow = DateTime.utc(2026, 8, 27);
      final container = ProviderContainer(
        overrides: [
          ...overrides(files(), (_, {mimeType}) async {}),
          artifactsControllerProvider.overrideWith(
            () => ArtifactsController(clock: () => fixedNow),
          ),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(artifactsControllerProvider.notifier);

      final created = await Future.wait([
        controller.create(title: 'First', content: 'one'),
        controller.create(title: 'Second', content: 'two'),
      ]);

      expect(created.map((artifact) => artifact.id).toSet(), hasLength(2));
      expect(container.read(artifactsControllerProvider), hasLength(2));
      expect(filesDir.listSync().whereType<File>(), hasLength(2));
    },
  );

  test('policy rejections leave no hive or disk residue', () async {
    final container = ProviderContainer(
      overrides: overrides(files(), (_, {mimeType}) async {}),
    );
    addTearDown(container.dispose);
    final notifier = container.read(artifactsControllerProvider.notifier);

    await expectLater(
      notifier.create(title: '   ', content: 'x'),
      throwsA(isA<ArtifactPolicyException>()),
    );
    await expectLater(
      notifier.create(
        title: 'Too big',
        // Pinned build_runner cannot parse digit-separated literals here.
        content: 'a' * (ArtifactPolicy.maxContentBytes + 1),
      ),
      throwsA(const ArtifactPolicyException('artifacts.errorContentTooLarge')),
    );

    expect(container.read(artifactsControllerProvider), isEmpty);
    expect(artifactsBox.length, 0);
    expect(filesDir.listSync().whereType<File>(), isEmpty);
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
            (path, {mimeType}) async => sharedPaths.add(path),
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

  testWidgets('editor surfaces policy errors inline', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocumentEditorSheet(
            onSave: (_, _) async => throw const ArtifactPolicyException(
              'artifacts.errorQuotaDocuments',
            ),
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('artifact-title-field')),
      'Notes',
    );
    await tester.enterText(
      find.byKey(const Key('artifact-content-field')),
      '# Agenda',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('artifact-save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('artifact-editor-error')), findsOneWidget);
    expect(find.byKey(const Key('artifact-save')), findsOneWidget);
  });

  testWidgets('editor exposes open and export actions for saved documents', (
    tester,
  ) async {
    final opened = <String>[];
    final exported = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocumentEditorSheet(
            artifact: Artifact(
              id: 'doc-1',
              title: 'Report',
              content: '# Report',
              createdAt: DateTime(2026),
              updatedAt: DateTime(2026),
            ),
            onSave: (_, _) async {},
            onOpen: () async => opened.add('md'),
            onExportDocx: () async => exported.add('docx'),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('artifact-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('artifact-export-docx')));
    await tester.pumpAndSettle();

    expect(opened, ['md']);
    expect(exported, ['docx']);
  });

  testWidgets('delete requires explicit confirmation', (tester) async {
    final deleted = <Artifact>[];
    final created = <Artifact>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          artifactShareBridgeProvider.overrideWithValue(
            (_, {mimeType}) async {},
          ),
          artifactsControllerProvider.overrideWith(
            () => _FakeController(created, deleted),
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
    await tester.enterText(
      find.byKey(const Key('artifact-content-field')),
      '# Agenda',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('artifact-save')));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'common.cancel'));
    await tester.pumpAndSettle();
    expect(deleted, isEmpty);
    expect(find.text('Meeting notes'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'chat.delete'));
    await tester.pumpAndSettle();
    expect(deleted, hasLength(1));
    expect(find.text('Meeting notes'), findsNothing);
  });
}

class _FakeController extends ArtifactsController {
  final List<Artifact> created;
  final List<Artifact> deleted;

  _FakeController(this.created, [this.deleted = const []]);

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
  Future<void> delete(Artifact artifact) async {
    deleted.add(artifact);
    created.removeWhere((item) => item.id == artifact.id);
    state = [...created];
  }

  @override
  Future<String> shareablePath(Artifact artifact) async =>
      '/tmp/${artifact.id}.md';
}
