import '../data/memory_file_store.dart';
import '../data/memory_repository.dart';
import 'memory_backup_codec.dart';
import 'memory_mutation_coordinator.dart';

class MemoryBackupService {
  MemoryBackupService(
    this._boundary,
    this._mutations, {
    MemoryBackupCodec codec = const MemoryBackupCodec(),
    DateTime Function()? now,
  }) : _codec = codec,
       _now = now ?? DateTime.now;

  static const documentExtension = MemoryBackupCodec.documentExtension;
  static const maxFileBytes = MemoryBackupCodec.maxFileBytes;
  static const maxDocumentBytes = MemoryBackupCodec.maxDocumentBytes;

  final MemoryFileBoundary _boundary;
  final MemoryMutationCoordinator _mutations;
  final MemoryBackupCodec _codec;
  final DateTime Function() _now;

  Future<String> createBackup() => _boundary.transaction((files) async {
    final contents = <String, String>{};
    for (final name in MemoryRepository.templates.keys) {
      contents[name] = await files.read(name);
    }
    return _codec.encode(contents, _now());
  });

  MemoryRestorePayload decodeRestore(String document) {
    final files = _codec.decode(document);
    return MemoryRestorePayload(
      files: files,
      totalBytes: files.values.fold(0, (sum, value) => sum + value.length),
    );
  }

  Future<void> restore(MemoryRestorePayload payload, String operationId) =>
      _mutations.mutate(
        event: 'restore_memory_backup',
        replacements: payload.files,
        operationId: operationId,
      );
}

class MemoryRestorePayload {
  MemoryRestorePayload({
    required Map<String, String> files,
    required this.totalBytes,
  }) : files = Map.unmodifiable(Map.of(files));
  final Map<String, String> files;
  final int totalBytes;
}

class MemoryRestorePreview {
  MemoryRestorePreview({
    required this.confirmationToken,
    required Map<String, String> files,
    required this.totalBytes,
  }) : files = Map.unmodifiable(Map.of(files));
  final String confirmationToken;
  final Map<String, String> files;
  final int totalBytes;
}

class UnknownMemoryRestoreException implements Exception {
  const UnknownMemoryRestoreException();
}
