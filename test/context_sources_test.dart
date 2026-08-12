import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/application/memory_recovery_journal.dart';
import 'package:mobilka/features/memory/data/context_sources.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';
import 'package:saf/saf.dart';

void main() {
  test('reads every selected file in one boundary snapshot', () async {
    final boundary = _Boundary({
      'user_profile.md': 'profile',
      'project_context.md': 'project',
    });
    final source = StoredMemoryContextSource(
      _Repository(boundary),
      MemoryMutationCoordinator(boundary),
    );

    expect(
      await source.readSnapshot(['user_profile.md', 'project_context.md']),
      {'user_profile.md': 'profile', 'project_context.md': 'project'},
    );
    expect(boundary.transactions, 1);
  });

  test('context snapshot awaits journal recovery before reading', () async {
    final boundary = _Boundary({
      'user_profile.md': 'after',
      'project_context.md': 'unrelated',
      'memory_log.md': '# Log\n',
    });
    final journal = InMemoryMemoryRecoveryJournal();
    await journal.write('operation', {
      'operationId': 'operation',
      'status': 'pending',
      'terminalAuditWritten': false,
      'previous': {
        'user_profile.md': base64Encode(utf8.encode('before')),
        'project_context.md': base64Encode(utf8.encode('project-before')),
        'memory_log.md': base64Encode(utf8.encode('# Log\n')),
      },
      'beforeHashes': {
        'user_profile.md': checksum('before'),
        'project_context.md': checksum('project-before'),
        'memory_log.md': checksum('# Log\n'),
      },
      'afterHashes': {
        'user_profile.md': checksum('after'),
        'project_context.md': checksum('project-after'),
      },
    });
    final source = StoredMemoryContextSource(
      _Repository(boundary),
      MemoryMutationCoordinator(boundary, journal: journal),
    );

    expect(await source.readSnapshot(['user_profile.md']), {
      'user_profile.md': 'before',
    });
    expect(boundary.transactions, 1);
    expect(await journal.readAll(), isEmpty);
  });
}

class _Repository extends MemoryRepository {
  _Repository(this.boundary) : super(Saf());
  final MemoryFileBoundary boundary;

  @override
  MemoryLocation? savedLocation() =>
      const MemoryLocation(value: 'test', isContentUri: false);

  @override
  MemoryFileBoundary boundaryFor(MemoryLocation location) => boundary;
}

class _Boundary implements MemoryFileBoundary, MemoryFileTransaction {
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
