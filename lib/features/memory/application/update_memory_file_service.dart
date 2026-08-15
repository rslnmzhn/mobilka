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
  final Set<String> _consumedTokens = {};
  final Set<String> _applyingTokens = {};

  Future<String> readCurrent(String fileName) {
    _validate(fileName);
    return _boundary.read(fileName);
  }

  Future<MemoryUpdatePreview> preparePreview(
    String fileName,
    String proposedContent,
  ) async {
    _validate(fileName);
    final current = await _mutations.readIfExists(fileName);
    final isCreate = current == null;
    final version = isCreate ? missingVersion : checksum(current);
    final nonce = _tokenFactory();
    final token = _confirmationToken(nonce, fileName, proposedContent, version);
    return MemoryUpdatePreview(
      fileName: fileName,
      proposedContent: proposedContent,
      diff: _buildDiff(fileName, current ?? '', proposedContent),
      confirmationToken: token,
      version: version,
      isCreate: isCreate,
    );
  }

  Future<MemoryUpdateResult> apply({
    required String confirmationToken,
    required String version,
  }) async {
    if (_consumedTokens.contains(confirmationToken) ||
        !_applyingTokens.add(confirmationToken)) {
      throw UnknownMemoryConfirmationException();
    }
    final payload = _decodeConfirmationToken(confirmationToken);
    try {
      final result = await applyPersisted(
        fileName: payload.fileName,
        proposedContent: payload.proposedContent,
        confirmationToken: confirmationToken,
        version: version,
      );
      _consumedTokens.add(confirmationToken);
      return result;
    } finally {
      _applyingTokens.remove(confirmationToken);
    }
  }

  Future<void> recover() => _mutations.recover();

  Future<MemoryUpdateResult> applyPersisted({
    required String fileName,
    required String proposedContent,
    required String confirmationToken,
    required String version,
  }) async {
    _validate(fileName);
    _validateConfirmationToken(
      fileName: fileName,
      proposedContent: proposedContent,
      confirmationToken: confirmationToken,
      version: version,
    );
    final current = await _mutations.readIfExists(fileName);
    final proposedVersion = checksum(proposedContent);
    if (current != null && checksum(current) == proposedVersion) {
      return MemoryUpdateResult(
        fileName: fileName,
        previousVersion: version,
        version: proposedVersion,
      );
    }
    final isCreate = version == missingVersion;
    try {
      await _mutations.mutate(
        event: 'update_memory_file',
        replacements: {fileName: proposedContent},
        expectedVersions: isCreate ? const {} : {fileName: version},
        createIfMissing: isCreate ? {fileName} : const {},
        operationId: confirmationToken,
      );
    } on StaleMemoryMutationException {
      throw const StaleMemoryPreviewException();
    } on MemoryMutationException catch (error) {
      throw MemoryAuditException(
        error.cause,
        rollbackSucceeded: error.rollbackSucceeded,
      );
    }
    return MemoryUpdateResult(
      fileName: fileName,
      previousVersion: version,
      version: proposedVersion,
    );
  }

  String _confirmationToken(
    String nonce,
    String fileName,
    String proposedContent,
    String version,
  ) {
    final payload = base64Url.encode(
      utf8.encode(jsonEncode({'file': fileName, 'content': proposedContent})),
    );
    return '$nonce.$payload.${checksum('$fileName\u0000$version\u0000$proposedContent\u0000$nonce')}';
  }

  ({String nonce, String fileName, String proposedContent})
  _decodeConfirmationToken(String confirmationToken) {
    final parts = confirmationToken.split('.');
    if (parts.length != 3 || parts.any((part) => part.isEmpty)) {
      throw const UnknownMemoryConfirmationException();
    }
    try {
      final payload =
          jsonDecode(utf8.decode(base64Url.decode(parts[1])))
              as Map<String, dynamic>;
      return (
        nonce: parts[0],
        fileName: payload['file'] as String,
        proposedContent: payload['content'] as String,
      );
    } on Object {
      throw const UnknownMemoryConfirmationException();
    }
  }

  void _validateConfirmationToken({
    required String fileName,
    required String proposedContent,
    required String confirmationToken,
    required String version,
  }) {
    final payload = _decodeConfirmationToken(confirmationToken);
    if (payload.fileName != fileName ||
        payload.proposedContent != proposedContent ||
        _confirmationToken(payload.nonce, fileName, proposedContent, version) !=
            confirmationToken) {
      throw const UnknownMemoryConfirmationException();
    }
  }

  static void _validate(String fileName) {
    if (!approvedFileNames.contains(fileName)) {
      throw FormatException('Memory file is not approved: $fileName');
    }
  }

  static const missingVersion = 'missing';
}

class MemoryUpdatePreview {
  const MemoryUpdatePreview({
    required this.fileName,
    required this.proposedContent,
    required this.diff,
    required this.confirmationToken,
    required this.version,
    this.isCreate = false,
  });
  final String fileName;
  final String proposedContent;
  final String diff;
  final String confirmationToken;
  final String version;
  final bool isCreate;
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
