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
import 'package:mobilka/features/artifacts/presentation/artifact_actions.dart';
import 'package:mobilka/features/artifacts/presentation/document_editor_sheet.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
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
      conversationId: 'conversation-1',
      sessionKey: '2026-08-23_notes',
    );

    final restored = Artifact.fromJson(artifact.toJson());

    expect(restored.id, artifact.id);
    expect(restored.title, artifact.title);
    expect(restored.content, artifact.content);
    expect(restored.createdAt, artifact.createdAt);
    expect(restored.updatedAt, artifact.updatedAt);
    expect(restored.conversationId, 'conversation-1');
    expect(restored.sessionKey, '2026-08-23_notes');
    expect(restored.docxSourceSha256, isNull);
    final edited = restored.copyWith(title: 'Edited');
    expect(edited.conversationId, restored.conversationId);
    expect(edited.sessionKey, restored.sessionKey);
  });

  test('legacy artifact ownership remains explicitly unknown', () {
    final restored = Artifact.fromJson({
      'id': 'legacy-artifact',
      'title': 'Legacy',
      'content': 'body',
      'createdAt': DateTime.utc(2026).toIso8601String(),
      'updatedAt': DateTime.utc(2026).toIso8601String(),
    });

    expect(restored.conversationId, isNull);
    expect(restored.sessionKey, isNull);
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

  test('stale caller cannot retarget immutable ownership on edit', () async {
    final container = ProviderContainer(
      overrides: overrides(files(), (_, {mimeType}) async {}),
    );
    addTearDown(container.dispose);
    final controller = container.read(artifactsControllerProvider.notifier);
    final canonical = await controller.create(
      title: 'Original',
      content: 'old',
      conversationId: 'owner-a',
      sessionKey: 'session-a',
    );
    final stale = Artifact(
      id: canonical.id,
      title: 'Stale',
      content: 'stale',
      createdAt: DateTime(1999),
      updatedAt: DateTime(1999),
      conversationId: 'owner-b',
      sessionKey: 'session-b',
    );

    await controller.update(stale, title: 'Edited', content: 'new');
    final saved = ArtifactStore().loadById(canonical.id)!;
    expect(saved.conversationId, 'owner-a');
    expect(saved.sessionKey, 'session-a');
    expect(saved.createdAt, canonical.createdAt);
    expect(saved.title, 'Edited');
    expect(saved.content, 'new');
  });

  test(
    'edit removes stale DOCX and export records current source hash',
    () async {
      final container = ProviderContainer(
        overrides: overrides(files(), (_, {mimeType}) async {}),
      );
      addTearDown(container.dispose);
      final controller = container.read(artifactsControllerProvider.notifier);
      final created = await controller.create(title: 'One', content: 'old');
      await controller.exportDocx(created);
      expect(ArtifactStore().loadById(created.id)!.docxSourceSha256, isNotNull);
      expect(await files().exists(created.id, extension: 'docx'), true);

      await controller.update(created, title: 'Two', content: 'new');
      expect(await files().exists(created.id, extension: 'docx'), false);
      expect(ArtifactStore().loadById(created.id)!.docxSourceSha256, isNull);

      await controller.exportDocx(created);
      expect(await files().exists(created.id, extension: 'docx'), true);
      expect(ArtifactStore().loadById(created.id)!.docxSourceSha256, isNotNull);
    },
  );

  test('export metadata failure restores prior DOCX bytes and hash', () async {
    final store = _ToggleSaveStore();
    final container = ProviderContainer(
      overrides: [
        ...overrides(files(), (_, {mimeType}) async {}),
        artifactStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(artifactsControllerProvider.notifier);
    final created = await controller.create(title: 'One', content: 'old');
    await controller.exportDocx(created);
    final before = store.loadById(created.id)!;
    final docx = File(p.join(filesDir.path, '${created.id}.docx'));
    final beforeBytes = await docx.readAsBytes();
    await files().write(created.id, 'changed');
    store.failNextSave = true;

    await expectLater(controller.exportDocx(created), throwsStateError);
    expect(await docx.readAsBytes(), beforeBytes);
    expect(
      store.loadById(created.id)!.docxSourceSha256,
      before.docxSourceSha256,
    );
  });

  test('failed first export restores absent DOCX and hash', () async {
    final store = _ToggleSaveStore();
    final container = ProviderContainer(
      overrides: [
        ...overrides(files(), (_, {mimeType}) async {}),
        artifactStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(artifactsControllerProvider.notifier);
    final created = await controller.create(title: 'One', content: 'old');
    store.failNextSave = true;

    await expectLater(controller.exportDocx(created), throwsStateError);
    expect(await files().exists(created.id, extension: 'docx'), false);
    expect(store.loadById(created.id)!.docxSourceSha256, isNull);
  });

  test('rollback metadata failure leaves export fail closed', () async {
    final store = _MultiFailSaveStore();
    final container = ProviderContainer(
      overrides: [
        ...overrides(files(), (_, {mimeType}) async {}),
        artifactStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(artifactsControllerProvider.notifier);
    final created = await controller.create(title: 'One', content: 'old');
    store.failuresRemaining = 2;

    await expectLater(
      controller.exportDocx(created),
      throwsA(isA<ArtifactMutationException>()),
    );
    expect(await files().exists(created.id, extension: 'docx'), false);
    expect(store.loadById(created.id)!.docxSourceSha256, isNull);
  });

  testWidgets('catalog share failure is localized and never leaks path', (
    tester,
  ) async {
    final artifact = Artifact(
      id: 'share-artifact',
      title: 'Share',
      content: 'body',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          artifactsControllerProvider.overrideWith(
            () => _ThrowingShareController(artifact),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: _ShareFailureHarness(artifact: artifact)),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('safe-share')));
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining(r'C:\private\secret.md'), findsNothing);
  });

  test(
    'representation revision follows create edit export and delete',
    () async {
      final container = ProviderContainer(
        overrides: overrides(files(), (_, {mimeType}) async {}),
      );
      addTearDown(container.dispose);
      final controller = container.read(artifactsControllerProvider.notifier);
      expect(container.read(artifactRepresentationsRevisionProvider), 0);

      final created = await controller.create(title: 'One', content: 'body');
      expect(container.read(artifactRepresentationsRevisionProvider), 1);
      expect(await files().stat(created.id, extension: 'md'), isNotNull);

      await controller.update(created, title: 'Two', content: 'longer body');
      expect(container.read(artifactRepresentationsRevisionProvider), 2);
      expect((await files().stat(created.id, extension: 'md'))?.size, 11);

      await controller.exportDocx(created);
      expect(container.read(artifactRepresentationsRevisionProvider), 3);
      expect(await files().stat(created.id, extension: 'docx'), isNotNull);

      await controller.delete(created);
      expect(container.read(artifactRepresentationsRevisionProvider), 4);
      expect(await files().stat(created.id, extension: 'md'), isNull);
      expect(await files().stat(created.id, extension: 'docx'), isNull);
    },
  );

  test('file write refreshes projection when metadata save fails', () async {
    final container = ProviderContainer(
      overrides: [
        ...overrides(files(), (_, {mimeType}) async {}),
        artifactStoreProvider.overrideWithValue(_SaveFailingStore()),
      ],
    );
    addTearDown(container.dispose);

    await expectLater(
      container
          .read(artifactsControllerProvider.notifier)
          .create(title: 'Failed', content: 'body'),
      throwsStateError,
    );
    expect(container.read(artifactRepresentationsRevisionProvider), 1);
    expect(filesDir.listSync().whereType<File>(), isEmpty);
  });

  test(
    'file deletion refreshes projection when metadata delete fails',
    () async {
      final store = _DeleteFailingStore();
      final container = ProviderContainer(
        overrides: [
          ...overrides(files(), (_, {mimeType}) async {}),
          artifactStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(artifactsControllerProvider.notifier);
      final artifact = await controller.create(title: 'Saved', content: 'body');
      final before = container.read(artifactRepresentationsRevisionProvider);
      store.failDelete = true;

      await expectLater(controller.delete(artifact), throwsStateError);
      expect(
        container.read(artifactRepresentationsRevisionProvider),
        before + 1,
      );
      expect(await files().stat(artifact.id, extension: 'md'), isNull);
    },
  );

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
        child: MaterialApp(
          home: Scaffold(
            body: ArtifactsBottomSheet(conversation: _ownedConversation()),
          ),
        ),
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
        child: MaterialApp(
          home: Scaffold(
            body: ArtifactsBottomSheet(conversation: _ownedConversation()),
          ),
        ),
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

Conversation _ownedConversation() => Conversation(
  id: 'conversation',
  title: 'Conversation',
  modelId: 'model',
  sessionKey: '2026-08-28_conversation',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  messages: const [],
);

class _SaveFailingStore extends ArtifactStore {
  @override
  Future<void> save(Artifact artifact) => Future.error(StateError('save'));
}

class _ToggleSaveStore extends ArtifactStore {
  bool failNextSave = false;

  @override
  Future<void> save(Artifact artifact) {
    if (failNextSave) {
      failNextSave = false;
      return Future.error(StateError('private metadata failure'));
    }
    return super.save(artifact);
  }
}

class _MultiFailSaveStore extends ArtifactStore {
  int failuresRemaining = 0;

  @override
  Future<void> save(Artifact artifact) {
    if (failuresRemaining > 0) {
      failuresRemaining--;
      return Future.error(StateError('private save failure'));
    }
    return super.save(artifact);
  }
}

class _ThrowingShareController extends ArtifactsController {
  _ThrowingShareController(this.artifact);
  final Artifact artifact;

  @override
  List<Artifact> build() => [artifact];

  @override
  Future<String> shareablePath(Artifact artifact) =>
      Future.error(StateError(r'C:\private\secret.md'));
}

class _ShareFailureHarness extends ConsumerWidget {
  const _ShareFailureHarness({required this.artifact});
  final Artifact artifact;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
    key: const Key('safe-share'),
    onPressed: () => safeShareArtifact(context, ref, artifact),
    child: const Text('Share'),
  );
}

class _DeleteFailingStore extends ArtifactStore {
  bool failDelete = false;

  @override
  Future<void> delete(String id) =>
      failDelete ? Future.error(StateError('delete')) : super.delete(id);
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
    String? conversationId,
    String? sessionKey,
  }) async {
    final artifact = Artifact(
      id: 'fake-${_seq++}',
      title: title,
      content: content,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      conversationId: conversationId,
      sessionKey: sessionKey,
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
