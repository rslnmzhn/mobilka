import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/memory_file_store.dart';
import '../data/memory_repository.dart';
import 'memory_mutation_coordinator.dart';

typedef ConfirmationTokenFactory = String Function();

final updateMemoryFileProvider = Provider<UpdateMemoryFileService?>((ref) {
  final repository = ref.watch(memoryRepositoryProvider);
  final location = repository.savedLocation();
  final mutations = ref.watch(memoryMutationCoordinatorProvider);
  if (location == null || mutations == null) return null;
  return UpdateMemoryFileService(repository.boundaryFor(location), mutations);
}, name: 'update_memory_file');

class UpdateMemoryFileService {
  UpdateMemoryFileService(
    this._boundary,
    this._mutations, {
    ConfirmationTokenFactory? tokenFactory,
  }) : _tokenFactory = tokenFactory ?? _secureToken;

  static const approvedFileNames = {
    'user_profile.md',
    'project_context.md',
    'system_instructions.md',
  };
  final MemoryFileBoundary _boundary;
  final MemoryMutationCoordinator _mutations;
  final ConfirmationTokenFactory _tokenFactory;
  final Map<String, _PendingUpdate> _pending = {};

  Future<String> readCurrent(String fileName) {
    _validate(fileName);
    return _boundary.read(fileName);
  }

  Future<MemoryUpdatePreview> preparePreview(
    String fileName,
    String proposedContent,
  ) async {
    _validate(fileName);
    final current = await _boundary.read(fileName);
    final version = checksum(current);
    final token = _tokenFactory();
    _pending[token] = _PendingUpdate(fileName, proposedContent, version);
    return MemoryUpdatePreview(
      fileName: fileName,
      diff: _buildDiff(fileName, current, proposedContent),
      confirmationToken: token,
      version: version,
    );
  }

  Future<MemoryUpdateResult> apply({
    required String confirmationToken,
    required String version,
  }) async {
    final update = _pending[confirmationToken];
    if (update == null || update.version != version) {
      throw const UnknownMemoryConfirmationException();
    }
    try {
      await _mutations.mutate(
        event: 'update_memory_file',
        replacements: {update.fileName: update.content},
        expectedVersions: {update.fileName: version},
        operationId: confirmationToken,
      );
    } on StaleMemoryMutationException {
      throw const StaleMemoryPreviewException();
    } on MemoryMutationException catch (error) {
      throw MemoryAuditException(
        error.cause,
        rollbackSucceeded: error.rollbackSucceeded,
      );
    } finally {
      _pending.remove(confirmationToken);
    }
    return MemoryUpdateResult(
      fileName: update.fileName,
      previousVersion: version,
      version: checksum(update.content),
    );
  }

  Future<void> recover() => _mutations.recover();

  static void _validate(String fileName) {
    if (!approvedFileNames.contains(fileName)) {
      throw FormatException('Memory file is not approved: $fileName');
    }
  }
}

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
}

class StaleMemoryPreviewException implements Exception {
  const StaleMemoryPreviewException();
}

class MemoryAuditException extends MemoryMutationException {
  const MemoryAuditException(super.cause, {required super.rollbackSucceeded});
}

class _PendingUpdate {
  const _PendingUpdate(this.fileName, this.content, this.version);
  final String fileName;
  final String content;
  final String version;
}

String _secureToken() {
  final random = Random.secure();
  return base64UrlEncode(
    List<int>.generate(24, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}

String _buildDiff(String fileName, String before, String after) {
  final beforeLines = const LineSplitter().convert(before);
  final afterLines = const LineSplitter().convert(after);
  return '${['--- $fileName', '+++ $fileName', ...beforeLines.map((line) => '-$line'), ...afterLines.map((line) => '+$line')].join('\n')}\n';
}
