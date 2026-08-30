import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/storage/app_boxes.dart';
import '../domain/memory_file_names.dart';
import '../data/memory_file_store.dart';
import '../data/memory_repository.dart';
import 'memory_recovery_journal.dart';
import 'persona_mutation_preflight.dart';

export 'persona_mutation_preflight.dart' show checksum;

part 'memory_mutation_recovery_helpers.dart';

final memoryMutationCoordinatorProvider = Provider<MemoryMutationCoordinator?>((
  ref,
) {
  final repository = ref.watch(memoryRepositoryProvider);
  final location = repository.savedLocation();
  if (location == null) return null;
  return createMemoryMutationCoordinator(
    repository: repository,
    location: location,
    logger: ref.read(appLoggerProvider),
  );
}, name: 'memory_mutation_coordinator');

/// Builds a coordinator for an already-configured [location].
MemoryMutationCoordinator createMemoryMutationCoordinator({
  required MemoryRepository repository,
  required MemoryLocation location,
  AppLogger? logger,
}) => MemoryMutationCoordinator(
  repository.boundaryFor(location),
  journal: HiveMemoryRecoveryJournal(
    memoryRecoveryBox,
    checksum(location.value),
  ),
  logger: logger,
);

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

  static const auditFile = MemoryFiles.memory;
  static const terminalAuditUtf8Headroom = 16 * 1024;
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
    Set<String> deletions = const {},
    Set<String> additionallyAllowed = const {},
    String? expectedPersonaMembership,
  }) => _mutate(
    event: event,
    replacements: replacements,
    expectedVersions: expectedVersions,
    createIfMissing: createIfMissing,
    operationId: operationId,
    deletions: deletions,
    additionallyAllowed: additionallyAllowed,
    expectedPersonaMembership: expectedPersonaMembership,
  );

  Future<void> migrateLegacyAlias({
    required String legacyName,
    required String modernName,
    required String backupName,
    required String content,
    bool backupAlreadyExists = false,
  }) {
    final valid = MemoryFiles.flattenedHistoricalAliases.any(
      (alias) => alias.key == legacyName && alias.value == modernName,
    );
    if (!valid || backupName != '$legacyName.migrated.bak') {
      throw const FormatException('Unsafe legacy migration target');
    }
    return _mutate(
      event: 'memory.legacy_migration',
      replacements: {
        backupName: content,
        modernName: content.endsWith('\n') ? content : '$content\n',
      },
      createIfMissing: backupAlreadyExists ? const {} : {backupName},
      deletions: {legacyName},
      additionallyAllowed: {legacyName, backupName},
      deferTerminalAudit: modernName == auditFile,
    );
  }

  Future<void> _mutate({
    required String event,
    required Map<String, String> replacements,
    Map<String, String> expectedVersions = const {},
    Set<String> createIfMissing = const {},
    Set<String> deletions = const {},
    Set<String> additionallyAllowed = const {},
    bool deferTerminalAudit = false,
    String? operationId,
    String? expectedPersonaMembership,
  }) => _boundary.transaction((files) async {
    await _recover(files);
    if (expectedPersonaMembership != null) {
      await validateExpectedPersonaMembership(
        files: files,
        expectedMembership: expectedPersonaMembership,
        stale: () => throw const StaleMemoryMutationException(),
      );
    }
    _validate(replacements.keys, additionallyAllowed: additionallyAllowed);
    if (deletions.isNotEmpty) {
      _validate(deletions, additionallyAllowed: additionallyAllowed);
    }
    if (!replacements.keys.toSet().containsAll(createIfMissing)) {
      throw const FormatException('Create targets must be replacements');
    }
    final before = <String, String>{};
    for (final name in {
      ...replacements.keys,
      ...deletions,
      ...expectedVersions.keys,
      auditFile,
    }) {
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
    await validatePersonaQuotaProjection(
      files: files,
      replacements: replacements,
      deletions: deletions,
    );
    final id = operationId ?? _operationId();
    final after = Map<String, String>.of(replacements);
    final record = <String, dynamic>{
      'timestamp': _now().toUtc().toIso8601String(),
      'event': event,
      'operationId': id,
      'status': 'pending',
      'terminalAuditWritten': false,
      if (deferTerminalAudit) 'terminalAuditDeferred': true,
      'files': replacements.keys.toList(growable: false),
      'createdFiles': createIfMissing.toList(growable: false),
      'deletedFiles': deletions.toList(growable: false),
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
    _validateAuditCapacity(before[auditFile]!, record);
    if (after.containsKey(auditFile)) {
      _validateAuditCapacity(after[auditFile]!, record);
    }
    _logger.log(event: 'memory.journal', operationId: id, status: 'pending');
    await _journal.write(id, record);
    try {
      for (final entry in after.entries) {
        await files.write(entry.key, entry.value);
      }
      if (deletions.isNotEmpty) {
        if (files is! DeletingMemoryFileTransaction) {
          throw StateError('Memory boundary cannot delete files');
        }
        final deletingFiles = files as DeletingMemoryFileTransaction;
        for (final name in deletions) {
          await deletingFiles.delete(name);
        }
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

  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) => _boundary.transaction((files) async {
    await _recover(files);
    return action(files);
  });

  Future<String?> _readIfExists(
    MemoryFileTransaction files,
    String fileName,
  ) async {
    if (files case final MissingAwareMemoryFileTransaction missingAware) {
      return missingAware.readIfExists(fileName);
    }
    // Plain boundaries treat absent files as unreadable; creation flows rely
    // on this mapping to null.
    try {
      return await files.read(fileName);
    } on Object {
      return null;
    }
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
    final deletedFiles = (record['deletedFiles'] as List<dynamic>? ?? const [])
        .cast<String>()
        .toSet();
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
      final current = await _readIfExists(files, entry.key);
      if (current == null || checksum(current) != entry.value) {
        fullyApplied = false;
        break;
      }
    }
    if (fullyApplied) {
      for (final name in deletedFiles) {
        if (await _readIfExists(files, name) != null) {
          fullyApplied = false;
          break;
        }
      }
    }
    if (fullyApplied) {
      final applied = {...record, 'status': 'applied'};
      await _journal.write(id, applied);
      await _finalize(files, applied, 'committed', recovered: recovered);
      await _removeFinalized(id);
      return _RecoveryOutcome.committed;
    }

    final createdFiles = (record['createdFiles'] as List<dynamic>? ?? const [])
        .cast<String>()
        .toSet();
    for (final entry in afterHashes.entries) {
      final current = await _readIfExists(files, entry.key);
      if (current == null) continue;
      final currentHash = checksum(current);
      if (currentHash == entry.value &&
          currentHash != beforeHashes[entry.key]) {
        if (createdFiles.contains(entry.key)) {
          if (files is! DeletingMemoryFileTransaction) {
            throw StateError('Memory boundary cannot roll back created files');
          }
          await (files as DeletingMemoryFileTransaction).delete(entry.key);
        } else {
          await files.write(entry.key, previous[entry.key]!);
        }
      }
    }
    for (final name in deletedFiles) {
      if (await _readIfExists(files, name) == null) {
        await files.write(name, previous[name]!);
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
    var auditDeferred = record['terminalAuditDeferred'] == true;
    if (!alreadyWritten &&
        !_containsAuditOperation(current, auditOperationId)) {
      final appended = _append(
        current,
        _terminalAuditEntry(
          {...record, 'timestamp': _now().toUtc().toIso8601String()},
          status,
          recovered: recovered,
        ),
      );
      if (auditDeferred) {
        _logger.log(
          event: 'memory.audit_deferred',
          operationId: operationId,
          status: status,
          level: AppLogLevel.warning,
        );
      } else if (utf8.encode(appended).length <= maxMemoryFileBytes) {
        await files.write(auditFile, appended);
      } else if (recovered) {
        auditDeferred = true;
        _logger.log(
          event: 'memory.audit_deferred',
          operationId: operationId,
          status: status,
          level: AppLogLevel.warning,
        );
      } else {
        throw const MemoryAuditCapacityException();
      }
    }
    await _journal.write(operationId, {
      ...record,
      'status': status,
      'terminalAuditWritten': !auditDeferred,
      if (auditDeferred) 'terminalAuditDeferred': true,
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

  static void _validate(
    Iterable<String> names, {
    Set<String> additionallyAllowed = const {},
  }) {
    if (names.any(
      (name) =>
          !MemoryFiles.mutationFiles.contains(name) &&
          !MemoryFileValidation.isPersonaPath(name) &&
          !additionallyAllowed.contains(name),
    )) {
      throw const FormatException('Memory mutation contains an unsafe file');
    }
  }

  static void _validateAuditCapacity(
    String auditContent,
    Map<String, dynamic> record,
  ) {
    final bytes = utf8.encode(auditContent).length;
    if (bytes > maxMemoryFileBytes - terminalAuditUtf8Headroom) {
      throw const MemoryAuditCapacityException();
    }
    for (final status in const ['committed', 'failed']) {
      final appended = _append(
        auditContent,
        _terminalAuditEntry(record, status, recovered: true),
      );
      if (utf8.encode(appended).length > maxMemoryFileBytes) {
        throw const MemoryAuditCapacityException();
      }
    }
  }
}

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

class MemoryAuditCapacityException implements Exception {
  const MemoryAuditCapacityException();

  @override
  String toString() =>
      'memory.md has insufficient space for the required mutation audit. '
      'Compact memory.md and retry; no content was written or truncated.';
}
