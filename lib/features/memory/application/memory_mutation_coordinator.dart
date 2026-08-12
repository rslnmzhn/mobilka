import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/memory_file_store.dart';
import '../data/memory_repository.dart';

final memoryMutationCoordinatorProvider = Provider<MemoryMutationCoordinator?>((
  ref,
) {
  final repository = ref.watch(memoryRepositoryProvider);
  final location = repository.savedLocation();
  if (location == null) return null;
  return MemoryMutationCoordinator(repository.boundaryFor(location));
}, name: 'memory_mutation_coordinator');

class MemoryMutationCoordinator {
  MemoryMutationCoordinator(
    this._boundary, {
    DateTime Function()? now,
    String Function()? operationId,
  }) : _now = now ?? DateTime.now,
       _operationId = operationId ?? _token;

  static const auditFile = 'memory_log.md';
  final MemoryFileBoundary _boundary;
  final DateTime Function() _now;
  final String Function() _operationId;

  Future<void> mutate({
    required String event,
    required Map<String, String> replacements,
    Map<String, String> expectedVersions = const {},
    String? operationId,
  }) => _boundary.transaction((files) async {
    await _recover(files);
    _validate(replacements.keys);
    final before = <String, String>{};
    for (final name in replacements.keys) {
      before[name] = await files.read(name);
      final expected = expectedVersions[name];
      if (expected != null && checksum(before[name]!) != expected) {
        throw const StaleMemoryMutationException();
      }
    }
    before.putIfAbsent(auditFile, () => '');
    if (!replacements.containsKey(auditFile)) {
      before[auditFile] = await files.read(auditFile);
    }
    final id = operationId ?? _operationId();
    final operation = <String, dynamic>{
      'timestamp': _now().toUtc().toIso8601String(),
      'event': event,
      'operationId': id,
      'files': replacements.keys.toList(growable: false),
      'previous': {
        for (final entry in before.entries)
          entry.key: base64Encode(utf8.encode(entry.value)),
      },
      'versions': {
        for (final entry in replacements.entries)
          entry.key: checksum(entry.value),
      },
      if (replacements.length == 1) ...{
        'fileName': replacements.keys.single,
        'previousVersion': checksum(before[replacements.keys.single]!),
        'version': checksum(replacements.values.single),
      },
    };
    final pending = {...operation, 'status': 'pending'};
    final pendingLog = _append(before[auditFile]!, pending);
    await files.write(auditFile, pendingLog);
    try {
      for (final entry in replacements.entries) {
        if (entry.key != auditFile) await files.write(entry.key, entry.value);
      }
      final finalBase = replacements[auditFile] ?? pendingLog;
      final withPending = replacements.containsKey(auditFile)
          ? _append(finalBase, pending)
          : finalBase;
      await files.write(
        auditFile,
        _append(withPending, {...operation, 'status': 'committed'}),
      );
    } on Object catch (error) {
      try {
        if (_latestStatus(await files.read(auditFile), id) == 'committed') {
          return;
        }
      } on Object {
        // Continue with rollback when commitment cannot be established.
      }
      var rolledBack = true;
      try {
        await _rollback(files, operation, before);
      } on Object {
        rolledBack = false;
      }
      throw MemoryMutationException(error, rollbackSucceeded: rolledBack);
    }
  });

  Future<void> recover() => _boundary.transaction(_recover);

  Future<void> _recover(MemoryFileTransaction files) async {
    final log = await files.read(auditFile);
    final latest = <String, Map<String, dynamic>>{};
    for (final line in const LineSplitter().convert(log)) {
      try {
        final value = jsonDecode(line);
        if (value is Map<String, dynamic> && value['operationId'] is String) {
          latest[value['operationId'] as String] = value;
        }
      } on FormatException {
        // Memory logs may contain user-authored Markdown.
      }
    }
    for (final entry in latest.values.where((e) => e['status'] == 'pending')) {
      final previous = _decodePrevious(entry['previous']);
      await _rollback(files, entry, previous, recovered: true);
    }
  }

  Future<void> _rollback(
    MemoryFileTransaction files,
    Map<String, dynamic> operation,
    Map<String, String> previous, {
    bool recovered = false,
  }) async {
    final versions = (operation['versions'] as Map).cast<String, dynamic>();
    for (final entry in versions.entries) {
      if (entry.key == auditFile) continue;
      if (checksum(await files.read(entry.key)) == entry.value) {
        await files.write(entry.key, previous[entry.key]!);
      }
    }
    final currentLog = await files.read(auditFile);
    await files.write(
      auditFile,
      _append(currentLog, {
        ...operation,
        'timestamp': _now().toUtc().toIso8601String(),
        'status': 'failed',
        if (recovered) 'recovered': true,
      }),
    );
  }

  static Map<String, String> _decodePrevious(Object? value) {
    if (value is! Map) throw const FormatException('Invalid memory journal');
    return value.map(
      (key, encoded) =>
          MapEntry(key as String, utf8.decode(base64Decode(encoded as String))),
    );
  }

  static String? _latestStatus(String content, String operationId) {
    String? result;
    for (final line in const LineSplitter().convert(content)) {
      try {
        final value = jsonDecode(line);
        if (value is Map<String, dynamic> &&
            value['operationId'] == operationId &&
            value['status'] is String) {
          result = value['status'] as String;
        }
      } on FormatException {
        // Ignore user-authored Markdown.
      }
    }
    return result;
  }

  static void _validate(Iterable<String> names) {
    if (names.isEmpty ||
        names.any((name) => !MemoryRepository.templates.containsKey(name))) {
      throw const FormatException('Memory mutation contains an unsafe file');
    }
  }
}

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

String _token() {
  final random = Random.secure();
  return base64UrlEncode(
    List<int>.generate(24, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}
