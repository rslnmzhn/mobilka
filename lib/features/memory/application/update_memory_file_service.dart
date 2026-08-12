import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synchronized/synchronized.dart';

import '../data/memory_file_store.dart';
import '../data/memory_repository.dart';

typedef ConfirmationTokenFactory = String Function();
typedef CurrentTime = DateTime Function();

final updateMemoryFileProvider = Provider<UpdateMemoryFileService?>((ref) {
  final repository = ref.watch(memoryRepositoryProvider);
  final location = repository.savedLocation();
  if (location == null) return null;
  return UpdateMemoryFileService(repository.boundaryFor(location));
}, name: 'update_memory_file');

class MemoryUpdatePreview {
  const MemoryUpdatePreview({
    required this.fileName,
    required this.diff,
    required this.confirmationToken,
    required this.version,
  });

  final String fileName;
  final String diff;
  final String confirmationToken;
  final String version;
}

class MemoryUpdateResult {
  const MemoryUpdateResult({
    required this.fileName,
    required this.previousVersion,
    required this.version,
  });

  final String fileName;
  final String previousVersion;
  final String version;
}

class UnknownMemoryConfirmationException implements Exception {
  const UnknownMemoryConfirmationException();

  @override
  String toString() => 'Unknown or already-applied memory confirmation token';
}

class StaleMemoryPreviewException implements Exception {
  const StaleMemoryPreviewException();

  @override
  String toString() => 'Memory changed after the preview was prepared';
}

class MemoryAuditException implements Exception {
  const MemoryAuditException(this.cause, {required this.rollbackSucceeded});

  final Object cause;
  final bool rollbackSucceeded;

  @override
  String toString() =>
      'Could not finish memory audit; rollback succeeded: '
      '$rollbackSucceeded; cause: $cause';
}

class UpdateMemoryFileService {
  UpdateMemoryFileService(
    this._boundary, {
    ConfirmationTokenFactory? tokenFactory,
    CurrentTime? now,
  }) : _tokenFactory = tokenFactory ?? _secureToken,
       _now = now ?? DateTime.now;

  static const approvedFileNames = {
    'user_profile.md',
    'project_context.md',
    'system_instructions.md',
  };
  static const _auditFileName = 'memory_log.md';

  final MemoryFileBoundary _boundary;
  final ConfirmationTokenFactory _tokenFactory;
  final CurrentTime _now;
  final Lock _pendingLock = Lock();
  final Map<String, _PendingUpdate> _pending = {};

  Future<String> readCurrent(String fileName) {
    _validateApprovedFile(fileName);
    return _boundary.read(fileName);
  }

  Future<MemoryUpdatePreview> preparePreview(
    String fileName,
    String proposedContent,
  ) async {
    _validateApprovedFile(fileName);
    final currentContent = await _boundary.read(fileName);
    final version = _contentVersion(currentContent);
    final token = _tokenFactory();
    await _pendingLock.synchronized(() {
      _pending[token] = _PendingUpdate(
        fileName: fileName,
        proposedContent: proposedContent,
        version: version,
      );
    });
    return MemoryUpdatePreview(
      fileName: fileName,
      diff: _buildDiff(fileName, currentContent, proposedContent),
      confirmationToken: token,
      version: version,
    );
  }

  Future<MemoryUpdateResult> apply({
    required String confirmationToken,
    required String version,
  }) async {
    final update = await _pendingLock.synchronized(
      () => _pending[confirmationToken],
    );
    if (update == null || update.version != version) {
      throw const UnknownMemoryConfirmationException();
    }

    try {
      final result = await _boundary.transaction((files) async {
        await _recoverUnlocked(files);
        final currentContent = await files.read(update.fileName);
        if (_contentVersion(currentContent) != update.version) {
          throw const StaleMemoryPreviewException();
        }

        final nextVersion = _contentVersion(update.proposedContent);
        var auditContent = await files.read(_auditFileName);
        final operation = {
          'timestamp': _now().toUtc().toIso8601String(),
          'event': 'update_memory_file',
          'operationId': confirmationToken,
          'fileName': update.fileName,
          'previousVersion': update.version,
          'version': nextVersion,
        };
        auditContent = await _appendAudit(files, auditContent, {
          ...operation,
          'status': 'pending',
        });

        try {
          await files.write(update.fileName, update.proposedContent);
          await _appendAudit(files, auditContent, {
            ...operation,
            'status': 'committed',
          });
        } on Object catch (error) {
          try {
            final observedAudit = await files.read(_auditFileName);
            if (_latestStatus(observedAudit, confirmationToken) ==
                'committed') {
              return MemoryUpdateResult(
                fileName: update.fileName,
                previousVersion: update.version,
                version: nextVersion,
              );
            }
          } on Object {
            // Continue with guarded rollback when commitment is not readable.
          }
          var rollbackSucceeded = false;
          try {
            final target = await files.read(update.fileName);
            if (_contentVersion(target) == nextVersion) {
              await files.write(update.fileName, currentContent);
            }
            rollbackSucceeded = true;
            await _appendAudit(files, auditContent, {
              ...operation,
              'status': 'failed',
            });
          } on Object {
            // The pending record lets the next transaction recover safely.
          }
          throw MemoryAuditException(
            error,
            rollbackSucceeded: rollbackSucceeded,
          );
        }

        return MemoryUpdateResult(
          fileName: update.fileName,
          previousVersion: update.version,
          version: nextVersion,
        );
      });
      await _pendingLock.synchronized(() => _pending.remove(confirmationToken));
      return result;
    } on StaleMemoryPreviewException {
      await _pendingLock.synchronized(() => _pending.remove(confirmationToken));
      rethrow;
    }
  }

  Future<void> recover() => _boundary.transaction(_recoverUnlocked);

  Future<void> _recoverUnlocked(MemoryFileTransaction files) async {
    var auditContent = await files.read(_auditFileName);
    final operations = <String, Map<String, dynamic>>{};
    for (final line in const LineSplitter().convert(auditContent)) {
      try {
        final entry = jsonDecode(line);
        if (entry is Map<String, dynamic> &&
            entry['event'] == 'update_memory_file' &&
            entry['operationId'] is String) {
          operations[entry['operationId'] as String] = entry;
        }
      } on FormatException {
        // User-authored Markdown around journal lines is allowed.
      }
    }
    for (final entry in operations.values.where(
      (entry) => entry['status'] == 'pending',
    )) {
      final fileName = entry['fileName'];
      if (fileName is! String || !approvedFileNames.contains(fileName)) {
        continue;
      }
      final currentVersion = _contentVersion(await files.read(fileName));
      final status = currentVersion == entry['version']
          ? 'committed'
          : 'failed';
      auditContent = await _appendAudit(files, auditContent, {
        ...entry,
        'timestamp': _now().toUtc().toIso8601String(),
        'status': status,
        'recovered': true,
      });
    }
  }

  static Future<String> _appendAudit(
    MemoryFileTransaction files,
    String content,
    Map<String, dynamic> entry,
  ) async {
    final updated = _appendLine(content, jsonEncode(entry));
    await files.write(_auditFileName, updated);
    return updated;
  }

  static String? _latestStatus(String content, String operationId) {
    String? status;
    for (final line in const LineSplitter().convert(content)) {
      try {
        final entry = jsonDecode(line);
        if (entry is Map<String, dynamic> &&
            entry['operationId'] == operationId &&
            entry['status'] is String) {
          status = entry['status'] as String;
        }
      } on FormatException {
        // Ignore non-journal Markdown lines.
      }
    }
    return status;
  }

  static void _validateApprovedFile(String fileName) {
    if (!approvedFileNames.contains(fileName)) {
      throw FormatException('Memory file is not approved: $fileName');
    }
  }
}

class _PendingUpdate {
  const _PendingUpdate({
    required this.fileName,
    required this.proposedContent,
    required this.version,
  });

  final String fileName;
  final String proposedContent;
  final String version;
}

String _contentVersion(String content) =>
    sha256.convert(utf8.encode(content)).toString();

String _secureToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(24, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

String _appendLine(String content, String line) {
  if (content.isEmpty) return '$line\n';
  return content.endsWith('\n') ? '$content$line\n' : '$content\n$line\n';
}

String _buildDiff(String fileName, String before, String after) {
  final beforeLines = const LineSplitter().convert(before);
  final afterLines = const LineSplitter().convert(after);
  var prefix = 0;
  while (prefix < beforeLines.length &&
      prefix < afterLines.length &&
      beforeLines[prefix] == afterLines[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < beforeLines.length - prefix &&
      suffix < afterLines.length - prefix &&
      beforeLines[beforeLines.length - suffix - 1] ==
          afterLines[afterLines.length - suffix - 1]) {
    suffix++;
  }
  final removed = beforeLines.sublist(prefix, beforeLines.length - suffix);
  final added = afterLines.sublist(prefix, afterLines.length - suffix);
  return '${['--- $fileName', '+++ $fileName', '@@ -${prefix + 1},${removed.length} +${prefix + 1},${added.length} @@', ...removed.map((line) => '-$line'), ...added.map((line) => '+$line')].join('\n')}\n';
}
