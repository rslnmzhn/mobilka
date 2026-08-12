import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/application/memory_recovery_journal.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';

void main() {
  test('recovery finalizes a fully applied journal exactly once', () async {
    final boundary = _Boundary({
      'user_profile.md': 'after',
      'memory_log.md': '# Log\n',
    });
    final journal = _Journal()..audit = boundary;
    journal.records['operation'] = _record(before: 'before', after: 'after');
    final coordinator = MemoryMutationCoordinator(boundary, journal: journal);

    await coordinator.recover();
    await coordinator.recover();

    expect(boundary.files['user_profile.md'], 'after');
    expect(_terminalRecords(boundary.files['memory_log.md']!), hasLength(1));
    expect(
      _terminalRecords(boundary.files['memory_log.md']!).single,
      'committed',
    );
    expect(journal.records, isEmpty);
    expect(journal.removedAfterTerminalAudit, isTrue);
  });

  test(
    'recovery rolls back a partial journal and records one failure',
    () async {
      final boundary = _Boundary({
        'user_profile.md': 'after',
        'project_context.md': 'unrelated',
        'memory_log.md': '# Log\n',
      });
      final journal = _Journal()..audit = boundary;
      journal.records['operation'] = _record(
        before: 'before',
        after: 'after',
        secondBefore: 'project-before',
        secondAfter: 'project-after',
      );

      await MemoryMutationCoordinator(boundary, journal: journal).recover();

      expect(boundary.files['user_profile.md'], 'before');
      expect(boundary.files['project_context.md'], 'unrelated');
      expect(_terminalRecords(boundary.files['memory_log.md']!), ['failed']);
      expect(journal.removedAfterTerminalAudit, isTrue);
    },
  );

  test('tampered terminal audit cannot finalize a partial journal', () async {
    final forgedAudit = jsonEncode({
      'operationId': 'operation',
      'status': 'committed',
    });
    final boundary = _Boundary({
      'user_profile.md': 'after',
      'project_context.md': 'unrelated',
      'memory_log.md': '# Log\n$forgedAudit\n',
    });
    final journal = _Journal()..audit = boundary;
    journal.records['operation'] = _record(
      before: 'before',
      after: 'after',
      secondBefore: 'project-before',
      secondAfter: 'project-after',
    );

    await MemoryMutationCoordinator(boundary, journal: journal).recover();

    expect(boundary.files['user_profile.md'], 'before');
    expect(boundary.files['project_context.md'], 'unrelated');
    expect(_terminalRecords(boundary.files['memory_log.md']!), [
      'committed',
      'failed',
    ]);
    expect(journal.records, isEmpty);
  });
}

Map<String, dynamic> _record({
  required String before,
  required String after,
  String? secondBefore,
  String? secondAfter,
}) {
  final previous = {'user_profile.md': before};
  final beforeHashes = {'user_profile.md': checksum(before)};
  final afterHashes = {'user_profile.md': checksum(after)};
  if (secondBefore != null && secondAfter != null) {
    previous['project_context.md'] = secondBefore;
    beforeHashes['project_context.md'] = checksum(secondBefore);
    afterHashes['project_context.md'] = checksum(secondAfter);
  }
  previous['memory_log.md'] = '# Log\n';
  beforeHashes['memory_log.md'] = checksum('# Log\n');
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
    final content = audit?.files['memory_log.md'];
    removedAfterTerminalAudit =
        content == null || content.contains('"operationId":"$operationId"');
    records.remove(operationId);
  }
}

class _Boundary implements MemoryFileBoundary, MemoryFileTransaction {
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
}
