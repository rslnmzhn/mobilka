import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/application/memory_recovery_journal.dart';
import 'package:mobilka/features/memory/data/context_sources.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';
import 'package:mobilka/features/memory/domain/memory_file_names.dart';
import 'package:path/path.dart' as p;
import 'package:saf/saf.dart';
import 'support/memory_delete_mixins.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mobilka-context');
    Hive.init(p.join(tempDir.path, 'hive'));
    await Hive.openBox<dynamic>('memory_recovery');
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk('memory_recovery');
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('reads every role file in one boundary snapshot', () async {
    final boundary = _Boundary({
      MemoryFiles.user: 'profile',
      MemoryFiles.soul: 'soul core',
    });
    final source = StoredMemoryContextSource(
      _Repository(boundary),
      () => MemoryMutationCoordinator(boundary),
    );

    expect(await source.readSnapshot([MemoryFiles.soul, MemoryFiles.user]), {
      MemoryFiles.soul: 'soul core',
      MemoryFiles.user: 'profile',
    });
    expect(boundary.transactions, 1);
  });

  test('context snapshot awaits journal recovery before reading', () async {
    final boundary = _Boundary({
      MemoryFiles.user: 'after',
      MemoryFiles.soul: 'unrelated',
      MemoryFiles.memory: '# Log\n',
    });
    final journal = InMemoryMemoryRecoveryJournal();
    await journal.write('operation', {
      'operationId': 'operation',
      'status': 'pending',
      'terminalAuditWritten': false,
      'previous': {
        MemoryFiles.user: base64Encode(utf8.encode('before')),
        MemoryFiles.soul: base64Encode(utf8.encode('soul-before')),
        MemoryFiles.memory: base64Encode(utf8.encode('# Log\n')),
      },
      'beforeHashes': {
        MemoryFiles.user: checksum('before'),
        MemoryFiles.soul: checksum('soul-before'),
        MemoryFiles.memory: checksum('# Log\n'),
      },
      'afterHashes': {
        MemoryFiles.user: checksum('after'),
        MemoryFiles.soul: checksum('soul-after'),
      },
    });
    final source = StoredMemoryContextSource(
      _Repository(boundary),
      () => MemoryMutationCoordinator(boundary, journal: journal),
    );

    expect(await source.readSnapshot([MemoryFiles.user]), {
      MemoryFiles.user: 'before',
    });
    expect(boundary.transactions, 1);
    expect(await journal.readAll(), isEmpty);
  });

  test('stale null coordinator falls back to a fresh coordinator', () async {
    // Regression: ChatRepository captured the coordinator provider value
    // before the memory folder existed; every request then failed with
    // "Memory recovery is unavailable for configured storage".
    final boundary = _Boundary({MemoryFiles.user: 'profile'});
    final source = StoredMemoryContextSource(_Repository(boundary), () => null);

    expect(await source.readSnapshot([MemoryFiles.user]), {
      MemoryFiles.user: 'profile',
    });
  });

  test('unconfigured location yields an empty snapshot', () async {
    final boundary = _Boundary({MemoryFiles.user: 'profile'});
    final repository = _Repository(boundary, configured: false);
    final source = StoredMemoryContextSource(repository, () => null);

    expect(await source.readSnapshot([MemoryFiles.user]), isEmpty);
    expect(boundary.transactions, 0);
  });
}

class _Repository extends MemoryRepository {
  _Repository(this.boundary, {this.configured = true}) : super(Saf());
  final MemoryFileBoundary boundary;
  final bool configured;

  @override
  MemoryLocation? savedLocation() => configured
      ? const MemoryLocation(value: 'test', isContentUri: false)
      : null;

  @override
  MemoryFileBoundary boundaryFor(MemoryLocation location) => boundary;
}

class _Boundary
    with MemoryBoundaryDelete
    implements MemoryFileBoundary, MemoryFileTransaction {
  _Boundary(this.files);
  final Map<String, String> files;
  int transactions = 0;

  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) async {
    transactions++;
    return action(this);
  }

  @override
  Future<String> read(String fileName) async => files[fileName]!;

  @override
  Future<void> write(String fileName, String content) async {
    files[fileName] = content;
  }
}
