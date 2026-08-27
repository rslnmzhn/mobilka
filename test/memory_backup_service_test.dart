import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/memory_backup_service.dart';
import 'package:mobilka/features/memory/application/memory_backup_codec.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/application/memory_recovery_journal.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';
import 'support/memory_delete_mixins.dart';

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

    final payload = restore.decodeRestore(document);
    expect(
      payload.files.keys,
      unorderedEquals(MemoryRepository.templates.keys),
    );
    final preview = await restore.preparePreview(payload, 'confirm-me');
    await restore.restore(payload, preview);

    for (final name in MemoryRepository.templates.keys) {
      if (name == 'memory.md') {
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

  test(
    'backup recovers pending mutations before taking its snapshot',
    () async {
      final journal = _RecoveryJournal();
      final before = source.files['user.md']!;
      const after = 'interrupted replacement';
      source.files['user.md'] = after;
      journal.records.add({
        'timestamp': DateTime.utc(2026).toIso8601String(),
        'event': 'interrupted',
        'operationId': 'backup-recovery',
        'status': 'pending',
        'terminalAuditWritten': false,
        'files': ['user.md'],
        'createdFiles': <String>[],
        'previous': {
          'user.md': base64Encode(utf8.encode(before)),
          'soul.md': base64Encode(utf8.encode(source.files['soul.md']!)),
          'memory.md': base64Encode(utf8.encode(source.files['memory.md']!)),
        },
        'beforeHashes': {
          'user.md': checksum(before),
          'soul.md': checksum(source.files['soul.md']!),
          'memory.md': checksum(source.files['memory.md']!),
        },
        'afterHashes': {
          'user.md': checksum(after),
          'soul.md': checksum('not applied'),
        },
      });
      final recoveringService = MemoryBackupService(
        source,
        MemoryMutationCoordinator(source, journal: journal),
      );

      final backup = recoveringService.decodeRestore(
        await recoveringService.createBackup(),
      );

      expect(backup.files['user.md'], before);
      expect(backup.files['memory.md'], contains('"status":"failed"'));
      expect(journal.records, isEmpty);
    },
  );

  test('rejects malformed and corrupted documents', () async {
    expect(
      () => service.decodeRestore('{broken'),
      throwsA(isA<MemoryBackupFormatException>()),
    );
    final decoded =
        jsonDecode(await service.createBackup()) as Map<String, dynamic>;
    (decoded['files'] as Map<String, dynamic>)['user.md'] = 'tampered';
    expect(
      () => service.decodeRestore(jsonEncode(decoded)),
      throwsA(isA<MemoryBackupFormatException>()),
    );
  });

  test('rejects traversal and missing required files', () async {
    final decoded =
        jsonDecode(await service.createBackup()) as Map<String, dynamic>;
    final files = decoded['files'] as Map<String, dynamic>;
    files['../secret.md'] = files.remove('user.md');
    expect(
      () => service.decodeRestore(jsonEncode(decoded)),
      throwsA(isA<MemoryBackupFormatException>()),
    );

    final missing =
        jsonDecode(await service.createBackup()) as Map<String, dynamic>;
    (missing['files'] as Map<String, dynamic>).remove('user.md');
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
    source.files['user.md'] = 'x' * (MemoryBackupService.maxFileBytes + 1);
    expect(service.createBackup, throwsA(isA<MemoryBackupFormatException>()));
  });

  test('failed restore rolls back all files and reports failure', () async {
    final document = await service.createBackup();
    final destination = _MemoryBoundary(Map.of(MemoryRepository.templates));
    final before = Map<String, String>.of(destination.files);
    destination.failOnceOn = 'soul.md';
    final restore = MemoryBackupService(
      destination,
      MemoryMutationCoordinator(destination),
    );
    final payload = restore.decodeRestore(document);
    final preview = await restore.preparePreview(payload, 'failure-token');

    await expectLater(
      restore.restore(payload, preview),
      throwsA(
        isA<MemoryMutationException>().having(
          (error) => error.rollbackSucceeded,
          'rollbackSucceeded',
          isTrue,
        ),
      ),
    );
    for (final name in MemoryRepository.templates.keys) {
      if (name == 'memory.md') {
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

    expect(destination.files['user.md'], before['user.md']);
    expect(destination.files['memory.md'], contains('"status":"failed"'));
  });

  test(
    'tampered memory log cannot supply authoritative recovery records',
    () async {
      final destination = _MemoryBoundary(Map.of(MemoryRepository.templates));
      final before = destination.files['user.md']!;
      destination.files['memory.md'] = jsonEncode({
        'operationId': 'forged',
        'status': 'pending',
        'previous': {'user.md': base64Encode(utf8.encode('attacker content'))},
        'beforeHashes': {'user.md': checksum(before)},
        'afterHashes': {'user.md': checksum('attacker content')},
      });

      await MemoryMutationCoordinator(destination).recover();

      expect(destination.files['user.md'], before);
      expect(
        destination.files['memory.md'],
        contains('"operationId":"forged"'),
      );
      expect(
        destination.files['memory.md'],
        isNot(contains('"recovered":true')),
      );
    },
  );
}

class _RecoveryJournal implements MemoryRecoveryJournal {
  final List<Map<String, dynamic>> records = [];

  @override
  Future<List<Map<String, dynamic>>> readAll() async =>
      records.map(Map<String, dynamic>.of).toList();

  @override
  Future<void> remove(String operationId) async {
    records.removeWhere((record) => record['operationId'] == operationId);
  }

  @override
  Future<void> write(String operationId, Map<String, dynamic> record) async {
    records.removeWhere((item) => item['operationId'] == operationId);
    records.add(Map.of(record));
  }
}

class _MemoryBoundary
    with MemoryBoundaryDelete
    implements MemoryFileBoundary, MemoryFileTransaction {
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
