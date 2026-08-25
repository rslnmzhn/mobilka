import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/memory_controller.dart';
import 'package:mobilka/features/memory/application/memory_backup_controller.dart';
import 'package:mobilka/features/memory/application/memory_backup_service.dart';
import 'package:mobilka/features/memory/application/memory_file_editor.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/application/memory_selection_controller.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';
import 'package:mobilka/features/memory/data/memory_selection_store.dart';
import 'package:mobilka/features/memory/presentation/memory_editor_sheet.dart';
import 'package:mobilka/features/memory/presentation/memory_backup_card.dart';
import 'package:mobilka/features/memory/presentation/memory_screen.dart';
import 'support/memory_delete_mixins.dart';

void main() {
  testWidgets('restore UI exposes exact reviewed content before confirmation', (
    tester,
  ) async {
    const current = 'current profile';
    const incoming = 'incoming profile';
    const diff = '--- current/user.md\n+++ incoming/user.md\n';
    final preview = MemoryRestorePreview(
      confirmationToken: 'token',
      files: const {
        'user.md': MemoryRestoreFilePreview(
          current: current,
          incoming: incoming,
          diff: diff,
          currentVersion: 'version',
        ),
      },
      totalBytes: incoming.length,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          memoryBackupControllerProvider.overrideWith(
            () => _PreviewBackupController(preview),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: MemoryBackupCard(enabled: true)),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('memory-restore-file-user.md')));
    await tester.pumpAndSettle();

    expect(find.text(current), findsOneWidget);
    expect(find.text(incoming), findsOneWidget);
    expect(find.text(diff), findsOneWidget);
    expect(find.byKey(const Key('memory-confirm-restore')), findsOneWidget);
  });

  test(
    'selection controller persists toggles and restores state on failure',
    () async {
      final values = <String>{...MemoryRepository.templates.keys};
      var fail = false;
      final store = MemorySelectionStore(
        read: (_, _) => values.toList(),
        write: (_, value) async {
          if (fail) throw StateError('persistence failed');
          values
            ..clear()
            ..addAll((value as List).cast<String>());
        },
      );
      final container = ProviderContainer(
        overrides: [memorySelectionStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      final controller = container.read(
        memorySelectionControllerProvider.notifier,
      );

      await controller.setIncluded('memory.md', included: false);
      expect(
        container.read(memorySelectionControllerProvider),
        isNot(contains('memory.md')),
      );
      expect(values, isNot(contains('memory.md')));

      fail = true;
      await expectLater(
        controller.setIncluded('user.md', included: false),
        throwsStateError,
      );
      expect(
        container.read(memorySelectionControllerProvider),
        contains('user.md'),
      );
    },
  );

  testWidgets('selection UI toggles a standard file through the controller', (
    tester,
  ) async {
    final values = <String>{...MemoryRepository.templates.keys};
    final store = MemorySelectionStore(
      read: (_, _) => values.toList(),
      write: (_, value) async {
        values
          ..clear()
          ..addAll((value as List).cast<String>());
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          memorySelectionStoreProvider.overrideWithValue(store),
          memoryControllerProvider.overrideWith(
            () => _MemoryLocationController(),
          ),
          memoryFileEditorProvider.overrideWithValue(null),
        ],
        child: const MaterialApp(home: MemoryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('memory-inclusion-user.md')));
    await tester.pumpAndSettle();
    expect(values, isNot(contains('user.md')));
  });

  testWidgets('editor reads and saves only after explicit save', (
    tester,
  ) async {
    final boundary = _Boundary(Map.of(MemoryRepository.templates));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryEditorSheet(
            fileName: 'user.md',
            editor: MemoryFileEditor(
              boundary,
              MemoryMutationCoordinator(boundary),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('memory-editor-content')),
      'edited',
    );
    expect(boundary.files['user.md'], isNot('edited'));

    await tester.tap(find.byKey(const Key('memory-editor-save')));
    await tester.pumpAndSettle();
    expect(boundary.files['user.md'], 'edited');
    expect(boundary.files['memory.md'], contains('manual_memory_edit'));
  });

  testWidgets('editor exposes safe read errors and disables save', (
    tester,
  ) async {
    final boundary = _Boundary(Map.of(MemoryRepository.templates))
      ..failReads = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryEditorSheet(
            fileName: 'user.md',
            editor: MemoryFileEditor(
              boundary,
              MemoryMutationCoordinator(boundary),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memory-editor-error')), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('memory-editor-save')),
    );
    expect(button.onPressed, isNull);
  });

  test('manual edit rejects a stale snapshot', () async {
    final boundary = _Boundary(Map.of(MemoryRepository.templates));
    final editor = MemoryFileEditor(
      boundary,
      MemoryMutationCoordinator(boundary),
    );
    final snapshot = await editor.read('user.md');
    boundary.files['user.md'] = 'changed elsewhere';

    await expectLater(
      editor.save('user.md', 'mine', expectedVersion: snapshot.version),
      throwsA(isA<StaleMemoryMutationException>()),
    );
    expect(boundary.files['user.md'], 'changed elsewhere');
  });

  test('manual edit finalizes when audit initially fails', () async {
    final boundary = _Boundary(Map.of(MemoryRepository.templates));
    final editor = MemoryFileEditor(
      boundary,
      MemoryMutationCoordinator(boundary),
    );
    final snapshot = await editor.read('user.md');
    boundary.failWriteNumber = 2;

    await editor.save('user.md', 'edited', expectedVersion: snapshot.version);
    expect(boundary.files['user.md'], 'edited');
    expect(boundary.files['memory.md'], contains('"status":"committed"'));
  });
}

class _PreviewBackupController extends MemoryBackupController {
  _PreviewBackupController(this.preview);
  final MemoryRestorePreview preview;

  @override
  MemoryBackupState build() => MemoryBackupState.pending(
    payload: MemoryRestorePayload(
      files: const {'user.md': 'incoming profile'},
      totalBytes: 'incoming profile'.length,
    ),
    preview: preview,
  );
}

class _MemoryLocationController extends MemoryController {
  @override
  Future<MemoryLocation?> build() async => null;
}

class _Boundary
    with MemoryBoundaryDelete
    implements MemoryFileBoundary, MemoryFileTransaction {
  _Boundary(this.files);
  final Map<String, String> files;
  bool failReads = false;
  int? failWriteNumber;
  int _writeNumber = 0;

  @override
  Future<String> read(String fileName) async {
    if (failReads) throw StateError('read failed');
    return files[fileName]!;
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) => action(this);

  @override
  Future<void> write(String fileName, String content) async {
    _writeNumber++;
    if (_writeNumber == failWriteNumber) throw StateError('write failed');
    files[fileName] = content;
  }
}
