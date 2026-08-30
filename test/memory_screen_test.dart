import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/memory_backup_controller.dart';
import 'package:mobilka/features/memory/application/memory_controller.dart';
import 'package:mobilka/features/memory/application/memory_file_editor.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/application/memory_selection_controller.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';
import 'package:mobilka/features/memory/data/memory_selection_store.dart';
import 'package:mobilka/features/memory/presentation/memory_screen.dart';
import 'support/memory_delete_mixins.dart';

void main() {
  const fileName = 'user.md';
  const content = '# Test profile\n\nLoaded from the fake memory boundary.\n';

  for (final size in const [Size(320, 720), Size(1280, 800)]) {
    testWidgets(
      'opens the memory editor without overflow at ${size.width}x${size.height}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final boundary = _MemoryBoundary({
          ...MemoryRepository.templates,
          fileName: content,
        });
        final editor = MemoryFileEditor(
          boundary,
          MemoryMutationCoordinator(boundary),
        );
        final selectionStore = MemorySelectionStore(
          read: (_, fallback) => fallback,
          write: (_, _) async {},
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              memoryControllerProvider.overrideWith(
                _MemoryLocationController.new,
              ),
              memoryBackupControllerProvider.overrideWith(
                _MemoryBackupController.new,
              ),
              memoryFileEditorProvider.overrideWithValue(editor),
              memorySelectionStoreProvider.overrideWithValue(selectionStore),
            ],
            child: const MaterialApp(home: MemoryScreen()),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('persona-clear')), findsNothing);

        await tester.scrollUntilVisible(
          find.byKey(const Key('memory-personas-folder')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.byKey(const Key('memory-personas-folder')), findsOneWidget);

        final editButton = find.byKey(const Key('memory-edit-$fileName'));
        expect(editButton, findsOneWidget);
        expect(editButton.hitTestable(), findsOneWidget);

        await tester.tap(editButton, warnIfMissed: false);
        await tester.pump();

        final editorContent = find.byKey(const Key('memory-editor-content'));
        expect(editorContent, findsOneWidget);
        expect(
          tester.widget<TextField>(editorContent).controller?.text,
          content,
        );
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

class _MemoryLocationController extends MemoryController {
  @override
  Future<MemoryLocation?> build() => Future.value(
    const MemoryLocation(value: '/fake/memory', isContentUri: false),
  );
}

class _MemoryBackupController extends MemoryBackupController {
  @override
  MemoryBackupState build() => const MemoryBackupState.empty();
}

class _MemoryBoundary
    with MemoryBoundaryDelete
    implements MemoryFileBoundary, MemoryFileTransaction {
  _MemoryBoundary(this.files);

  final Map<String, String> files;

  @override
  Future<String> read(String fileName) async => files[fileName]!;

  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) => action(this);

  @override
  Future<void> write(String fileName, String content) async {
    files[fileName] = content;
  }
}
