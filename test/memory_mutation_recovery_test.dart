import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/application/memory_recovery_journal.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'support/memory_delete_mixins.dart';

void main() {
  test(
    'preflight reserves terminal audit space before journal or writes',
    () async {
      final audit =
          'x' *
          (maxMemoryFileBytes -
              MemoryMutationCoordinator.terminalAuditUtf8Headroom +
              1);
      final boundary = _Boundary({'user.md': 'before', 'memory.md': audit});
      final journal = _Journal()..audit = boundary;

      await expectLater(
        MemoryMutationCoordinator(
          boundary,
          journal: journal,
        ).mutate(event: 'test', replacements: const {'user.md': 'after'}),
        throwsA(isA<MemoryAuditCapacityException>()),
      );

      expect(boundary.files['user.md'], 'before');
      expect(boundary.files['memory.md'], audit);
      expect(journal.records, isEmpty);
    },
  );

  test('replacement memory must leave terminal audit headroom', () async {
    final boundary = _Boundary({'memory.md': 'before'});
    final journal = _Journal()..audit = boundary;
    final replacement =
        'é' *
        ((maxMemoryFileBytes -
                MemoryMutationCoordinator.terminalAuditUtf8Headroom) ~/
            2);

    await MemoryMutationCoordinator(
      boundary,
      journal: journal,
    ).mutate(event: 'test', replacements: {'memory.md': replacement});

    expect(
      utf8.encode(boundary.files['memory.md']!).length,
      lessThanOrEqualTo(maxMemoryFileBytes),
    );
    expect(boundary.files['memory.md'], startsWith(replacement));
  });

  test('recovery finalizes a fully applied journal exactly once', () async {
    final boundary = _Boundary({'user.md': 'after', 'memory.md': '# Log\n'});
    final journal = _Journal()..audit = boundary;
    journal.records['operation'] = _singleRecord(
      file: 'user.md',
      before: 'before',
      after: 'after',
    );
    final coordinator = MemoryMutationCoordinator(boundary, journal: journal);

    await coordinator.recover();
    await coordinator.recover();

    expect(boundary.files['user.md'], 'after');
    expect(_terminalRecords(boundary.files['memory.md']!), hasLength(1));
    expect(_terminalRecords(boundary.files['memory.md']!).single, 'committed');
    expect(journal.records, isEmpty);
    expect(journal.removedAfterTerminalAudit, isTrue);
  });

  test(
    'recovery rolls back a partial journal and records one failure',
    () async {
      final boundary = _Boundary({
        'user.md': 'after',
        'soul.md': 'unrelated',
        'memory.md': '# Log\n',
      });
      final journal = _Journal()..audit = boundary;
      journal.records['operation'] = _twoFileRecord(
        file1: 'user.md',
        before1: 'before',
        after1: 'after',
        file2: 'soul.md',
        before2: 'soul-before',
        after2: 'soul-after',
      );

      await MemoryMutationCoordinator(boundary, journal: journal).recover();

      expect(boundary.files['user.md'], 'before');
      expect(boundary.files['soul.md'], 'unrelated');
      expect(_terminalRecords(boundary.files['memory.md']!), ['failed']);
      expect(journal.removedAfterTerminalAudit, isTrue);
    },
  );

  test('tampered terminal audit cannot finalize a partial journal', () async {
    final forgedAudit = jsonEncode({
      'operationId': 'operation',
      'status': 'committed',
    });
    final boundary = _Boundary({
      'user.md': 'after',
      'soul.md': 'unrelated',
      'memory.md': '# Log\n$forgedAudit\n',
    });
    final journal = _Journal()..audit = boundary;
    journal.records['operation'] = _twoFileRecord(
      file1: 'user.md',
      before1: 'before',
      after1: 'after',
      file2: 'soul.md',
      before2: 'soul-before',
      after2: 'soul-after',
    );

    await MemoryMutationCoordinator(boundary, journal: journal).recover();

    expect(boundary.files['user.md'], 'before');
    expect(boundary.files['soul.md'], 'unrelated');
    expect(_terminalRecords(boundary.files['memory.md']!), [
      'committed',
      'failed',
    ]);
    expect(journal.records, isEmpty);
  });

  test('recovery before create leaves the missing target absent', () async {
    final boundary = _Boundary({'memory.md': '# Log\n'});
    final journal = _Journal()..audit = boundary;
    journal.records['operation'] = _createRecord();

    await MemoryMutationCoordinator(boundary, journal: journal).recover();

    expect(boundary.files.containsKey('user.md'), isFalse);
    expect(_terminalRecords(boundary.files['memory.md']!), ['failed']);
    expect(journal.records, isEmpty);
  });

  test('recovery after create finalizes the applied creation', () async {
    final boundary = _Boundary({'user.md': 'created', 'memory.md': '# Log\n'});
    final journal = _Journal()..audit = boundary;
    journal.records['operation'] = _createRecord();

    await MemoryMutationCoordinator(boundary, journal: journal).recover();

    expect(boundary.files['user.md'], 'created');
    expect(_terminalRecords(boundary.files['memory.md']!), ['committed']);
    expect(journal.records, isEmpty);
  });

  test(
    'mixed create and replace rollback deletes rather than empties create',
    () async {
      final boundary = _Boundary({
        'user.md': 'created',
        'soul.md': 'unrelated',
        'memory.md': '# Log\n',
      });
      final journal = _Journal()..audit = boundary;
      journal.records['operation'] = _createAndReplaceRecord();

      await MemoryMutationCoordinator(boundary, journal: journal).recover();

      expect(boundary.files.containsKey('user.md'), isFalse);
      expect(boundary.files['soul.md'], 'unrelated');
      expect(_terminalRecords(boundary.files['memory.md']!), ['failed']);
    },
  );

  test('near-limit legacy recovery defers audit without truncation', () async {
    final audit = 'x' * (maxMemoryFileBytes - 1);
    final boundary = _Boundary({'user.md': 'after', 'memory.md': audit});
    final journal = _Journal()..audit = boundary;
    journal.records['operation'] = _singleRecord(
      file: 'user.md',
      before: 'before',
      after: 'after',
    );
    final coordinator = MemoryMutationCoordinator(boundary, journal: journal);

    await coordinator.recover();

    expect(boundary.files['memory.md'], audit);
    expect(journal.records, isEmpty);
    await expectLater(
      coordinator.mutate(
        event: 'new mutation',
        replacements: const {'user.md': 'next'},
      ),
      throwsA(isA<MemoryAuditCapacityException>()),
    );
    expect(boundary.files['user.md'], 'after');
  });
}

Map<String, dynamic> _createRecord() {
  final record = _singleRecord(file: 'user.md', before: '', after: 'created');
  record['createdFiles'] = ['user.md'];
  return record;
}

Map<String, dynamic> _createAndReplaceRecord() {
  final record = _twoFileRecord(
    file1: 'user.md',
    before1: '',
    after1: 'created',
    file2: 'soul.md',
    before2: 'before',
    after2: 'after',
  );
  record['createdFiles'] = ['user.md'];
  return record;
}

Map<String, dynamic> _singleRecord({
  required String file,
  required String before,
  required String after,
}) => _twoFileRecord(file1: file, before1: before, after1: after);

Map<String, dynamic> _twoFileRecord({
  required String file1,
  required String before1,
  required String after1,
  String? file2,
  String? before2,
  String? after2,
}) {
  final previous = {file1: before1};
  final beforeHashes = {file1: checksum(before1)};
  final afterHashes = {file1: checksum(after1)};
  if (file2 != null) {
    previous[file2] = before2!;
    beforeHashes[file2] = checksum(before2);
    afterHashes[file2] = checksum(after2!);
  }
  previous['memory.md'] = '# Log\n';
  beforeHashes['memory.md'] = checksum('# Log\n');
  return {
    'timestamp': DateTime.utc(2026).toIso8601String(),
    'event': 'test',
    'operationId': 'operation',
    'status': 'pending',
    'previous': {
      for (final entry in previous.entries)
        entry.key: base64Encode(utf8.encode(entry.value)),
    },
    'beforeHashes': beforeHashes,
    'afterHashes': afterHashes,
  };
}

List<String> _terminalRecords(String audit) => const LineSplitter()
    .convert(audit)
    .map((line) {
      try {
        return jsonDecode(line);
      } on FormatException {
        return null;
      }
    })
    .whereType<Map<String, dynamic>>()
    .where((record) => record['operationId'] == 'operation')
    .map((record) => record['status'] as String)
    .where((status) => status == 'committed' || status == 'failed')
    .toList();

class _Journal implements MemoryRecoveryJournal {
  final Map<String, Map<String, dynamic>> records = {};
  _Boundary? audit;
  bool removedAfterTerminalAudit = false;

  @override
  Future<List<Map<String, dynamic>>> readAll() async =>
      records.values.map(Map<String, dynamic>.of).toList();

  @override
  Future<void> write(String operationId, Map<String, dynamic> record) async {
    records[operationId] = Map.of(record);
  }

  @override
  Future<void> remove(String operationId) async {
    final content = audit?.files['memory.md'];
    removedAfterTerminalAudit =
        content == null || content.contains('"operationId":"$operationId"');
    records.remove(operationId);
  }
}

class _Boundary
    with MemoryBoundaryDelete
    implements
        MemoryFileBoundary,
        MemoryFileTransaction,
        DeletingMemoryFileTransaction {
  _Boundary(this.files);
  final Map<String, String> files;

  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) => action(this);

  @override
  Future<String> read(String fileName) async => files[fileName]!;

  @override
  Future<void> write(String fileName, String content) async {
    files[fileName] = content;
  }

  @override
  Future<void> delete(String fileName) async {
    files.remove(fileName);
  }
}
