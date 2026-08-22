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

  Future<MemoryRestorePreview> preparePreview(
    MemoryRestorePayload payload,
    String confirmationToken,
  ) => _boundary.transaction((files) async {
    final previews = <String, MemoryRestoreFilePreview>{};
    for (final entry in payload.files.entries) {
      final current = await files.read(entry.key);
      previews[entry.key] = MemoryRestoreFilePreview(
        current: current,
        incoming: entry.value,
        diff: _buildDiff(entry.key, current, entry.value),
        currentVersion: checksum(current),
      );
    }
    return MemoryRestorePreview(
      confirmationToken: confirmationToken,
      files: previews,
      totalBytes: payload.totalBytes,
    );
  });

  Future<void> restore(
    MemoryRestorePayload payload,
    MemoryRestorePreview preview,
  ) => _mutations.mutate(
    event: 'restore_memory_backup',
    replacements: payload.files,
    expectedVersions: {
      for (final entry in preview.files.entries)
        entry.key: entry.value.currentVersion,
    },
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
    required Map<String, MemoryRestoreFilePreview> files,
    required this.totalBytes,
  }) : files = Map.unmodifiable(Map.of(files));
  final String confirmationToken;
  final Map<String, MemoryRestoreFilePreview> files;
  final int totalBytes;
}

class MemoryRestoreFilePreview {
  const MemoryRestoreFilePreview({
    required this.current,
    required this.incoming,
    required this.diff,
    required this.currentVersion,
  });

  final String current;
  final String incoming;
  final String diff;
  final String currentVersion;
}

String _buildDiff(String fileName, String before, String after) {
  final beforeLines = before.split('\n');
  final afterLines = after.split('\n');
  return '${['--- current/$fileName', '+++ incoming/$fileName', ...beforeLines.map((line) => '-$line'), ...afterLines.map((line) => '+$line')].join('\n')}\n';
}

class UnknownMemoryRestoreException implements Exception {
  const UnknownMemoryRestoreException();
}
