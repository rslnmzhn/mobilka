import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/memory_backup_codec.dart';
import 'package:mobilka/features/memory/application/memory_backup_controller.dart';
import 'package:mobilka/features/memory/application/memory_backup_service.dart';
import 'package:mobilka/features/memory/application/memory_controller.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/data/memory_backup_document_adapter.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';

void main() {
  test(
    'state exposes exact immutable current, incoming, and diff content',
    () async {
      final fixture = _Fixture(['first']);
      addTearDown(fixture.dispose);

      await fixture.controller.chooseRestore();
      final state = fixture.container.read(memoryBackupControllerProvider);

      expect(state.hasPendingRestore, isTrue);
      expect(state.payload!.files['user_profile.md'], 'first');
      final file = state.preview!.files['user_profile.md']!;
      expect(file.current, MemoryRepository.templates['user_profile.md']);
      expect(file.incoming, 'first');
      expect(
        file.diff,
        '--- current/user_profile.md\n'
        '+++ incoming/user_profile.md\n'
        '-# User Profile\n'
        '-\n'
        '-Add stable facts and preferences here.\n'
        '-\n'
        '+first\n',
      );
      expect(
        () => state.preview!.files['user_profile.md'] = file,
        throwsUnsupportedError,
      );
    },
  );

  test('replacement makes only the latest restore confirmable', () async {
    final fixture = _Fixture(['first', 'second']);
    addTearDown(fixture.dispose);

    await fixture.controller.chooseRestore();
    final firstToken = fixture.state.preview!.confirmationToken;
    await fixture.controller.chooseRestore();

    expect(fixture.state.payload!.files['user_profile.md'], 'second');
    expect(fixture.state.preview!.confirmationToken, isNot(firstToken));
    await fixture.controller.confirmRestore();
    expect(fixture.destination.files['user_profile.md'], 'second');
  });

  test('cancellation clears the entire pending restore state', () async {
    final fixture = _Fixture(['cancelled']);
    addTearDown(fixture.dispose);

    await fixture.controller.chooseRestore();
    fixture.controller.cancelRestore();

    expect(fixture.state.hasPendingRestore, isFalse);
    expect(fixture.state.payload, isNull);
    expect(fixture.state.preview, isNull);
    await expectLater(
      fixture.controller.confirmRestore(),
      throwsA(isA<UnknownMemoryRestoreException>()),
    );
  });

  test('confirmation consumes pending state exactly once', () async {
    final fixture = _Fixture(['confirmed']);
    addTearDown(fixture.dispose);

    await fixture.controller.chooseRestore();
    await fixture.controller.confirmRestore();

    expect(fixture.state.hasPendingRestore, isFalse);
    await expectLater(
      fixture.controller.confirmRestore(),
      throwsA(isA<UnknownMemoryRestoreException>()),
    );
  });

  test('location invalidation and disposal discard pending restore', () async {
    final fixture = _Fixture(['location', 'disposed']);
    addTearDown(fixture.dispose);

    await fixture.controller.chooseRestore();
    fixture.locationController.changeLocation();
    await fixture.container.pump();
    expect(fixture.state.hasPendingRestore, isFalse);

    await fixture.controller.chooseRestore();
    fixture.subscription.close();
    await fixture.container.pump();
    fixture.listen();
    expect(fixture.state.hasPendingRestore, isFalse);
  });
}

class _Fixture {
  _Fixture(List<String> documents)
    : destination = _MemoryBoundary(Map.of(MemoryRepository.templates)),
      adapter = _BackupAdapter(
        documents.map((value) => _document(value)).toList(),
      ) {
    final service = MemoryBackupService(
      destination,
      MemoryMutationCoordinator(destination),
    );
    container = ProviderContainer(
      overrides: [
        memoryControllerProvider.overrideWith(_MemoryController.new),
        memoryBackupDocumentAdapterProvider.overrideWithValue(adapter),
        memoryBackupServiceProvider.overrideWithValue(service),
      ],
    );
    listen();
  }

  final _MemoryBoundary destination;
  final _BackupAdapter adapter;
  late final ProviderContainer container;
  late ProviderSubscription<MemoryBackupState> subscription;

  MemoryBackupController get controller =>
      container.read(memoryBackupControllerProvider.notifier);
  _MemoryController get locationController =>
      container.read(memoryControllerProvider.notifier) as _MemoryController;
  MemoryBackupState get state => container.read(memoryBackupControllerProvider);

  void listen() {
    subscription = container.listen(memoryBackupControllerProvider, (_, _) {});
  }

  void dispose() => container.dispose();
}

class _MemoryController extends MemoryController {
  @override
  Future<MemoryLocation?> build() => Completer<MemoryLocation?>().future;

  void changeLocation() {
    state = const AsyncData(
      MemoryLocation(value: 'changed', isContentUri: false),
    );
  }
}

class _BackupAdapter implements MemoryBackupDocumentAdapter {
  _BackupAdapter(this.documents);
  final List<String> documents;

  @override
  Future<bool> exportDocument(String document) async => true;

  @override
  Future<String?> importDocument() async => documents.removeAt(0);
}

class _MemoryBoundary implements MemoryFileBoundary, MemoryFileTransaction {
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

String _document(String value) => const MemoryBackupCodec().encode({
  for (final name in MemoryRepository.templates.keys) name: value,
}, DateTime.utc(2026, 8, 12));
