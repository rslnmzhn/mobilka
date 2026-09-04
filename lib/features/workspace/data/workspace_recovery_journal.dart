import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:synchronized/synchronized.dart';

import '../../../core/storage/app_boxes.dart';

const workspaceJournalMaxBytes = 16 * 1024 * 1024;
const workspaceJournalMaxRecordBytes = 3 * 1024 * 1024;
const workspaceJournalMaxQuarantineRecords = 16;

abstract interface class WorkspaceRecoveryJournal {
  Future<void> put(String key, Map<String, Object?> record);
  Future<void> remove(String key);
  Future<void> quarantine(
    String key,
    Object? record,
    String reason, {
    Object? expectedActiveRecord,
  });
  Map<String, Object?> snapshot();
  Map<String, Object?> activeSnapshot();
}

final class HiveWorkspaceRecoveryJournal implements WorkspaceRecoveryJournal {
  HiveWorkspaceRecoveryJournal({Box<dynamic>? box})
    : _box = box ?? workspaceRecoveryBox;

  static const maxRecords = 32;
  final Box<dynamic> _box;
  static final Expando<Lock> _locks = Expando();
  Lock get _lock => _locks[_box] ??= Lock();

  @override
  Future<void> put(String key, Map<String, Object?> record) =>
      _lock.synchronized(() async {
        final encoded = utf8.encode(jsonEncode(record)).length;
        if (encoded > workspaceJournalMaxRecordBytes) {
          throw StateError('workspace_journal_record_too_large');
        }
        if (_box.length >= maxRecords && !_box.containsKey(key)) {
          throw StateError('workspace_journal_full');
        }
        var total = encoded;
        for (final entry in _box.toMap().entries) {
          if (entry.key == key) continue;
          total += _encodedSize(entry.value);
          if (total > workspaceJournalMaxBytes) {
            throw StateError('workspace_journal_full');
          }
        }
        await _box.put(key, record);
      });

  @override
  Future<void> remove(String key) => _lock.synchronized(() => _box.delete(key));

  @override
  Future<void> quarantine(
    String key,
    Object? record,
    String reason, {
    Object? expectedActiveRecord,
  }) => _lock.synchronized(() async {
    if (expectedActiveRecord != null &&
        !_sameRecord(_box.get(key), expectedActiveRecord)) {
      throw StateError('workspace_journal_record_changed');
    }
    final activeRecord = _box.get(key);
    final quarantineKey = 'quarantine.$key';
    final value = <String, Object?>{
      'version': 1,
      'state': 'invalid',
      'sourceKey': key,
      'reason': reason,
      'quarantinedAt': DateTime.now().toUtc().toIso8601String(),
      'record': record,
    };
    if (_encodedSize(value) > workspaceJournalMaxRecordBytes) {
      value['record'] = null;
      value['reason'] = 'oversized_invalid_record';
    }
    try {
      await _box.put(quarantineKey, value);
      final quarantined = _box.keys
          .whereType<String>()
          .where((candidate) => candidate.startsWith('quarantine.'))
          .toList();
      while (quarantined.length > workspaceJournalMaxQuarantineRecords) {
        await _box.delete(quarantined.removeAt(0));
      }
      await _box.delete(key);
    } on Object {
      if (activeRecord != null && !_box.containsKey(key)) {
        await _box.put(key, activeRecord);
      }
      rethrow;
    }
  });

  @override
  Map<String, Object?> snapshot() => Map<String, Object?>.from(_box.toMap());

  @override
  Map<String, Object?> activeSnapshot() => Map<String, Object?>.fromEntries(
    _box
        .toMap()
        .entries
        .where(
          (entry) =>
              entry.key is String &&
              !(entry.key as String).startsWith('quarantine.'),
        )
        .map((entry) => MapEntry(entry.key as String, entry.value)),
  );
}

final class InMemoryWorkspaceRecoveryJournal
    implements WorkspaceRecoveryJournal {
  final Map<String, Map<String, Object?>> records = {};
  final Map<String, Object?> invalidRecords = {};

  @override
  Future<void> put(String key, Map<String, Object?> record) async {
    if (_encodedSize(record) > workspaceJournalMaxRecordBytes) {
      throw StateError('workspace_journal_record_too_large');
    }
    final replacement = records[key];
    final total =
        records.values.fold<int>(0, (sum, item) => sum + _encodedSize(item)) -
        (replacement == null ? 0 : _encodedSize(replacement)) +
        _encodedSize(record);
    if (total > workspaceJournalMaxBytes) {
      throw StateError('workspace_journal_full');
    }
    records[key] = Map.unmodifiable(record);
  }

  @override
  Future<void> remove(String key) async => records.remove(key);

  @override
  Future<void> quarantine(
    String key,
    Object? record,
    String reason, {
    Object? expectedActiveRecord,
  }) async {
    if (expectedActiveRecord != null &&
        !_sameRecord(records[key], expectedActiveRecord)) {
      throw StateError('workspace_journal_record_changed');
    }
    invalidRecords[key] = record;
    while (invalidRecords.length > workspaceJournalMaxQuarantineRecords) {
      invalidRecords.remove(invalidRecords.keys.first);
    }
    records.remove(key);
  }

  @override
  Map<String, Object?> snapshot() => {
    ...records,
    for (final entry in invalidRecords.entries)
      'quarantine.${entry.key}': entry.value,
  };

  @override
  Map<String, Object?> activeSnapshot() => Map<String, Object?>.from(records);
}

int _encodedSize(Object? value) {
  try {
    return utf8.encode(jsonEncode(value)).length;
  } on Object {
    return workspaceJournalMaxBytes + 1;
  }
}

bool _sameRecord(Object? first, Object? second) {
  try {
    return jsonEncode(first) == jsonEncode(second);
  } on Object {
    return false;
  }
}
