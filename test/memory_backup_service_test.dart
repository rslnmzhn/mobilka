import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/memory_backup_service.dart';
import 'package:mobilka/features/memory/application/memory_backup_codec.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';

void main() {
  late _MemoryBoundary source;
  late MemoryBackupService service;

  setUp(() {
    source = _MemoryBoundary({
      for (final entry in MemoryRepository.templates.entries)
        entry.key: '${entry.value}source',
    });
    service = MemoryBackupService(
      source,
      MemoryMutationCoordinator(source),
      now: () => DateTime.utc(2026, 8, 12),
    );
  });

  test('backup roundtrip validates and restores all standard files', () async {
    final document = await service.createBackup();
    final destination = _MemoryBoundary(Map.of(MemoryRepository.templates));
    final restore = MemoryBackupService(
      destination,
      MemoryMutationCoordinator(destination),
      now: () => DateTime.utc(2026, 8, 12),
    );

    final preview = restore.decodeRestore(document);
    expect(
      preview.files.keys,
      unorderedEquals(MemoryRepository.templates.keys),
    );
    await restore.restore(preview, 'confirm-me');

    for (final name in MemoryRepository.templates.keys) {
      if (name == 'memory_log.md') {
        expect(destination.files[name], contains('restore_memory_backup'));
      } else {
        expect(destination.files[name], source.files[name]);
      }
    }
  });

  test('preview does not mutate memory before explicit confirmation', () async {
    final before = Map<String, String>.of(source.files);
    final document = await service.createBackup();
    service.decodeRestore(document);
    expect(source.files, before);
  });

  test('rejects malformed and corrupted documents', () async {
    expect(
      () => service.decodeRestore('{broken'),
      throwsA(isA<MemoryBackupFormatException>()),
    );
    final decoded =
        jsonDecode(await service.createBackup()) as Map<String, dynamic>;
    (decoded['files'] as Map<String, dynamic>)['user_profile.md'] = 'tampered';
    expect(
      () => service.decodeRestore(jsonEncode(decoded)),
      throwsA(isA<MemoryBackupFormatException>()),
    );
  });

  test('rejects traversal and missing required files', () async {
    final decoded =
        jsonDecode(await service.createBackup()) as Map<String, dynamic>;
    final files = decoded['files'] as Map<String, dynamic>;
    files['../secret.md'] = files.remove('user_profile.md');
    expect(
      () => service.decodeRestore(jsonEncode(decoded)),
      throwsA(isA<MemoryBackupFormatException>()),
    );

    final missing =
        jsonDecode(await service.createBackup()) as Map<String, dynamic>;
    (missing['files'] as Map<String, dynamic>).remove('project_context.md');
    expect(
      () => service.decodeRestore(jsonEncode(missing)),
      throwsA(isA<MemoryBackupFormatException>()),
    );
  });

  test('rejects oversized documents and individual files', () async {
    expect(
      () => service.decodeRestore(
        'x' * (MemoryBackupService.maxDocumentBytes + 1),
      ),
      throwsA(isA<MemoryBackupFormatException>()),
    );
    source.files['user_profile.md'] =
        'x' * (MemoryBackupService.maxFileBytes + 1);
    expect(service.createBackup, throwsA(isA<MemoryBackupFormatException>()));
  });

  test('failed restore rolls back all files and reports failure', () async {
    final document = await service.createBackup();
    final destination = _MemoryBoundary(Map.of(MemoryRepository.templates));
    final before = Map<String, String>.of(destination.files);
    destination.failOnceOn = 'system_instructions.md';
    final restore = MemoryBackupService(
      destination,
      MemoryMutationCoordinator(destination),
    );
    final preview = restore.decodeRestore(document);

    await expectLater(
      restore.restore(preview, 'failure-token'),
      throwsA(
        isA<MemoryMutationException>().having(
          (error) => error.rollbackSucceeded,
          'rollbackSucceeded',
          isTrue,
        ),
      ),
    );
    for (final name in MemoryRepository.templates.keys) {
      if (name == 'memory_log.md') {
        expect(destination.files[name], startsWith(before[name]!));
        expect(destination.files[name], contains('"status":"failed"'));
      } else {
        expect(destination.files[name], before[name]);
      }
    }
  });

  test('startup recovery rolls back a partially interrupted restore', () async {
    final destination = _MemoryBoundary(Map.of(MemoryRepository.templates));
    final before = Map<String, String>.of(destination.files);
    final coordinator = MemoryMutationCoordinator(
      destination,
      operationId: () => 'interrupted-restore',
    );
    destination.failWriteNumber = 3;
    destination.failRollback = true;

    await expectLater(
      coordinator.mutate(
        event: 'restore_memory_backup',
        replacements: {
          for (final name in MemoryRepository.templates.keys)
            name: 'restored $name',
        },
      ),
      throwsA(isA<MemoryMutationException>()),
    );
    destination
      ..failWriteNumber = null
      ..failRollback = false;
    await MemoryMutationCoordinator(destination).recover();

    expect(destination.files['user_profile.md'], before['user_profile.md']);
    expect(destination.files['memory_log.md'], contains('"recovered":true'));
  });
}

class _MemoryBoundary implements MemoryFileBoundary, MemoryFileTransaction {
  _MemoryBoundary(this.files);
  final Map<String, String> files;
  String? failOnceOn;
  int? failWriteNumber;
  bool failRollback = false;
  int _writeNumber = 0;

  @override
  Future<String> read(String fileName) async => files[fileName]!;

  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) => action(this);

  @override
  Future<void> write(String fileName, String content) async {
    _writeNumber++;
    if (failOnceOn == fileName) {
      failOnceOn = null;
      throw StateError('write failed');
    }
    if (_writeNumber == failWriteNumber ||
        (failRollback && content.contains('# User Profile'))) {
      throw StateError('write failed');
    }
    files[fileName] = content;
  }
}
