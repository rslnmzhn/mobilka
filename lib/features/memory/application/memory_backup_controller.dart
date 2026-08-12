import 'dart:convert';
import 'dart:math';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../data/memory_backup_document_adapter.dart';
import '../data/memory_repository.dart';
import 'memory_backup_service.dart';
import 'memory_controller.dart';
import 'memory_mutation_coordinator.dart';

part 'memory_backup_controller.g.dart';

final memoryBackupDocumentAdapterProvider =
    Provider<MemoryBackupDocumentAdapter>(
      (ref) => PlatformMemoryBackupDocumentAdapter(),
      name: 'memory_backup_document_adapter',
    );

final memoryBackupServiceProvider = Provider<MemoryBackupService?>((ref) {
  final repository = ref.watch(memoryRepositoryProvider);
  final location = repository.savedLocation();
  final mutations = ref.watch(memoryMutationCoordinatorProvider);
  if (location == null || mutations == null) return null;
  return MemoryBackupService(repository.boundaryFor(location), mutations);
}, name: 'memory_backup_service');

@riverpod
class MemoryBackupController extends _$MemoryBackupController {
  @override
  MemoryBackupState build() {
    ref.watch(memoryControllerProvider);
    return const MemoryBackupState.empty();
  }

  Future<bool> createBackup() async {
    final document = await _service.createBackup();
    return ref
        .read(memoryBackupDocumentAdapterProvider)
        .exportDocument(document);
  }

  Future<MemoryRestorePreview?> chooseRestore() async {
    state = const MemoryBackupState.empty();
    final document = await ref
        .read(memoryBackupDocumentAdapterProvider)
        .importDocument();
    if (document == null) return null;
    final payload = _service.decodeRestore(document);
    final token = _token();
    final preview = await _service.preparePreview(payload, token);
    state = MemoryBackupState.pending(payload: payload, preview: preview);
    return preview;
  }

  Future<void> confirmRestore() async {
    final pending = state;
    if (!pending.hasPendingRestore) {
      throw const UnknownMemoryRestoreException();
    }
    state = const MemoryBackupState.empty();
    await _service.restore(pending.payload!, pending.preview!);
  }

  void cancelRestore() => state = const MemoryBackupState.empty();

  MemoryBackupService get _service {
    final service = ref.read(memoryBackupServiceProvider);
    if (service == null) throw StateError('Choose a memory folder first');
    return service;
  }
}

class MemoryBackupState {
  const MemoryBackupState.empty() : payload = null, preview = null;

  const MemoryBackupState.pending({
    required MemoryRestorePayload this.payload,
    required MemoryRestorePreview this.preview,
  });

  final MemoryRestorePayload? payload;
  final MemoryRestorePreview? preview;

  bool get hasPendingRestore => payload != null;
}

String _token() {
  final random = Random.secure();
  return base64UrlEncode(
    List<int>.generate(24, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}
