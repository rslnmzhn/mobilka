import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/storage/app_boxes.dart';
import '../data/memory_file_store.dart';
import '../data/memory_repository.dart';
import 'memory_recovery_journal.dart';

final memoryMutationCoordinatorProvider = Provider<MemoryMutationCoordinator?>((
  ref,
) {
  final repository = ref.watch(memoryRepositoryProvider);
  final location = repository.savedLocation();
  if (location == null) return null;
  return MemoryMutationCoordinator(
    repository.boundaryFor(location),
    journal: HiveMemoryRecoveryJournal(
      memoryRecoveryBox,
      checksum(location.value),
    ),
    logger: ref.read(appLoggerProvider),
  );
}, name: 'memory_mutation_coordinator');

class MemoryMutationCoordinator {
  MemoryMutationCoordinator(
    this._boundary, {
    MemoryRecoveryJournal? journal,
    DateTime Function()? now,
    String Function()? operationId,
    AppLogger? logger,
  }) : _now = now ?? DateTime.now,
       _operationId = operationId ?? _token,
       _journal = journal ?? _journalFor(_boundary),
       _logger = logger ?? AppLogger();

  static const auditFile = 'memory_log.md';
  final MemoryFileBoundary _boundary;
  final DateTime Function() _now;
  final String Function() _operationId;
  final MemoryRecoveryJournal _journal;
  final AppLogger _logger;

  Future<void> mutate({
    required String event,
    required Map<String, String> replacements,
    Map<String, String> expectedVersions = const {},
    Set<String> createIfMissing = const {},
    String? operationId,
  }) => _boundary.transaction((files) async {
    await _recover(files);
    _validate(replacements.keys);
    if (!replacements.keys.toSet().containsAll(createIfMissing)) {
      throw const FormatException('Create targets must be replacements');
    }
    final before = <String, String>{};
    for (final name in {...replacements.keys, auditFile}) {
      before[name] = createIfMissing.contains(name)
          ? (await _readIfExists(files, name) ?? '')
          : await files.read(name);
    }
    for (final name in createIfMissing) {
      if (await _readIfExists(files, name) != null) {
        throw const StaleMemoryMutationException();
      }
    }
    for (final entry in expectedVersions.entries) {
      if (checksum(before[entry.key]!) != entry.value) {
        throw const StaleMemoryMutationException();
      }
    }

    final id = operationId ?? _operationId();
    final after = Map<String, String>.of(replacements);
    final record = <String, dynamic>{
      'timestamp': _now().toUtc().toIso8601String(),
      'event': event,
      'operationId': id,
      'status': 'pending',
      'terminalAuditWritten': false,
      'files': replacements.keys.toList(growable: false),
      'createdFiles': createIfMissing.toList(growable: false),
      'previous': {
        for (final entry in before.entries)
          entry.key: base64Encode(utf8.encode(entry.value)),
      },
      'beforeHashes': {
        for (final entry in before.entries) entry.key: checksum(entry.value),
      },
      'afterHashes': {
        for (final entry in after.entries) entry.key: checksum(entry.value),
      },
      if (replacements.length == 1) ...{
        'fileName': replacements.keys.single,
        'previousVersion': checksum(before[replacements.keys.single]!),
        'version': checksum(replacements.values.single),
      },
    };
    _logger.log(event: 'memory.journal', operationId: id, status: 'pending');
    await _journal.write(id, record);
    try {
      for (final entry in after.entries) {
        await files.write(entry.key, entry.value);
      }
      final applied = {...record, 'status': 'applied'};
      await _journal.write(id, applied);
      await _finalize(files, applied, 'committed');
      await _removeFinalized(id);
      _logger.log(
        event: 'memory.journal',
        operationId: id,
        status: 'committed',
      );
    } on Object catch (error) {
      _RecoveryOutcome? outcome;
      try {
        outcome = await _recoverRecord(files, record, recovered: false);
      } on Object {
        // The durable journal remains available for startup recovery.
      }
      if (outcome == _RecoveryOutcome.committed) return;
      throw MemoryMutationException(
        error,
        rollbackSucceeded: outcome == _RecoveryOutcome.rolledBack,
      );
    }
  });

  Future<void> recover() => _boundary.transaction(_recover);

  Future<String?> readIfExists(String fileName) =>
      _boundary.transaction((files) async {
        await _recover(files);
        return _readIfExists(files, fileName);
      });

  Future<Map<String, String>> readContextSnapshot(Iterable<String> fileNames) =>
      _boundary.transaction((files) async {
        await _recover(files);
        final snapshot = <String, String>{};
        for (final fileName in fileNames) {
          snapshot[fileName] = await files.read(fileName);
        }
        return Map.unmodifiable(snapshot);
      });

  Future<String?> _readIfExists(MemoryFileTransaction files, String fileName) {
    if (files case final MissingAwareMemoryFileTransaction missingAware) {
      return missingAware.readIfExists(fileName);
    }
    return files.read(fileName).then<String?>((content) => content);
  }

  Future<void> _recover(MemoryFileTransaction files) async {
    for (final record in await _journal.readAll()) {
      final operationId = record['operationId'];
      _logger.log(
        event: 'memory.recovery',
        operationId: operationId is String ? operationId : null,
        status: 'started',
      );
      await _recoverRecord(files, record, recovered: true);
      _logger.log(
        event: 'memory.recovery',
        operationId: operationId is String ? operationId : null,
        status: 'succeeded',
      );
    }
  }

  Future<_RecoveryOutcome> _recoverRecord(
    MemoryFileTransaction files,
    Map<String, dynamic> record, {
    required bool recovered,
  }) async {
    final id = record['operationId'];
    if (id is! String) throw const FormatException('Invalid memory journal');
    final previous = _decodePrevious(record['previous']);
    final beforeHashes = _decodeHashes(record['beforeHashes']);
    final afterHashes = _decodeHashes(record['afterHashes']);
    if (previous.keys
            .toSet()
            .difference(beforeHashes.keys.toSet())
            .isNotEmpty ||
        afterHashes.keys.any(
          (name) =>
              !previous.containsKey(name) || !beforeHashes.containsKey(name),
        )) {
      throw const FormatException('Invalid memory journal');
    }

    var fullyApplied = true;
    for (final entry in afterHashes.entries) {
      if (checksum(await files.read(entry.key)) != entry.value) {
        fullyApplied = false;
        break;
      }
    }
    if (fullyApplied) {
      final applied = {...record, 'status': 'applied'};
      await _journal.write(id, applied);
      await _finalize(files, applied, 'committed', recovered: recovered);
      await _removeFinalized(id);
      return _RecoveryOutcome.committed;
    }

    for (final entry in afterHashes.entries) {
      final currentHash = checksum(await files.read(entry.key));
      if (currentHash == entry.value &&
          currentHash != beforeHashes[entry.key]) {
        await files.write(entry.key, previous[entry.key]!);
      }
    }
    await _finalize(files, record, 'failed', recovered: recovered);
    await _removeFinalized(id);
    return _RecoveryOutcome.rolledBack;
  }

  Future<void> _finalize(
    MemoryFileTransaction files,
    Map<String, dynamic> record,
    String status, {
    bool recovered = false,
  }) async {
    final operationId = record['operationId'] as String;
    final auditOperationId = 'memory-mutation:$operationId:$status';
    final current = await files.read(auditFile);
    final alreadyWritten =
        record['terminalAuditWritten'] == true && record['status'] == status;
    if (!alreadyWritten &&
        !_containsAuditOperation(current, auditOperationId)) {
      await files.write(
        auditFile,
        _append(current, <String, dynamic>{
          'timestamp': _now().toUtc().toIso8601String(),
          'event': record['event'],
          'operationId': operationId,
          'status': status,
          'auditOperationId': auditOperationId,
          'files': record['files'],
          'createdFiles': record['createdFiles'],
          'beforeHashes': record['beforeHashes'],
          'afterHashes': record['afterHashes'],
          if (record.containsKey('fileName')) 'fileName': record['fileName'],
          if (record.containsKey('previousVersion'))
            'previousVersion': record['previousVersion'],
          if (record.containsKey('version')) 'version': record['version'],
          if (recovered) 'recovered': true,
        }),
      );
    }
    await _journal.write(operationId, {
      ...record,
      'status': status,
      'terminalAuditWritten': true,
    });
  }

  Future<void> _removeFinalized(String operationId) async {
    try {
      await _journal.remove(operationId);
    } on Object {
      // Recovery re-verifies file hashes before retrying journal removal.
    }
  }

  static Map<String, String> _decodePrevious(Object? value) {
    if (value is! Map) throw const FormatException('Invalid memory journal');
    return value.map(
      (key, encoded) => MapEntry(
        key as String,
        utf8.decode(base64Decode(encoded as String), allowMalformed: false),
      ),
    );
  }

  static Map<String, String> _decodeHashes(Object? value) {
    if (value is! Map) throw const FormatException('Invalid memory journal');
    return value.cast<String, String>();
  }

  static void _validate(Iterable<String> names) {
    if (names.isEmpty ||
        names.any((name) => !MemoryRepository.templates.containsKey(name))) {
      throw const FormatException('Memory mutation contains an unsafe file');
    }
  }
}

enum _RecoveryOutcome { committed, rolledBack }

final Expando<MemoryRecoveryJournal> _testJournals = Expando();

MemoryRecoveryJournal _journalFor(MemoryFileBoundary boundary) =>
    _testJournals[boundary] ??= InMemoryMemoryRecoveryJournal();

class StaleMemoryMutationException implements Exception {
  const StaleMemoryMutationException();
}

class MemoryMutationException implements Exception {
  const MemoryMutationException(this.cause, {required this.rollbackSucceeded});
  final Object cause;
  final bool rollbackSucceeded;
}

String checksum(String content) =>
    sha256.convert(utf8.encode(content)).toString();

String _append(String content, Map<String, dynamic> entry) {
  final line = jsonEncode(entry);
  if (content.isEmpty) return '$line\n';
  return content.endsWith('\n') ? '$content$line\n' : '$content\n$line\n';
}

bool _containsAuditOperation(String content, String auditOperationId) {
  for (final line in const LineSplitter().convert(content)) {
    try {
      final value = jsonDecode(line);
      if (value is Map && value['auditOperationId'] == auditOperationId) {
        return true;
      }
    } on FormatException {
      // Markdown headings and user-authored lines are not audit records.
    }
  }
  return false;
}

String _token() {
  final random = Random.secure();
  return base64UrlEncode(
    List<int>.generate(24, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}
