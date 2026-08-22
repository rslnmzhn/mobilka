import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/storage/app_boxes.dart';
import '../data/memory_file_store.dart';
import '../data/memory_repository.dart';
import 'memory_mutation_coordinator.dart';
import 'memory_update_proposal_authority.dart';

typedef ConfirmationTokenFactory = String Function();

final updateMemoryFileProvider = Provider<UpdateMemoryFileService?>((ref) {
  final repository = ref.watch(memoryRepositoryProvider);
  final location = repository.savedLocation();
  final mutations = ref.watch(memoryMutationCoordinatorProvider);
  if (location == null || mutations == null) return null;
  return UpdateMemoryFileService(
    repository.boundaryFor(location),
    mutations,
    proposals: ref.read(memoryUpdateProposalAuthorityProvider),
    locationId: checksum(location.value),
    logger: ref.read(appLoggerProvider),
  );
}, name: 'update_memory_file');

final memoryUpdateProposalAuthorityProvider =
    Provider<MemoryUpdateProposalAuthority>(
      (ref) => HiveMemoryUpdateProposalAuthority(memoryProposalBox),
    );

class UpdateMemoryFileService {
  UpdateMemoryFileService(
    this._boundary,
    this._mutations, {
    ConfirmationTokenFactory? tokenFactory,
    MemoryUpdateProposalAuthority? proposals,
    String locationId = 'test-location',
    AppLogger? logger,
  }) : _tokenFactory = tokenFactory ?? _secureToken,
       _proposals = proposals ?? InMemoryMemoryUpdateProposalAuthority(),
       _locationId = locationId,
       _logger = logger ?? AppLogger();

  static const approvedFileNames = {
    'user_profile.md',
    'project_context.md',
    'system_instructions.md',
  };
  final MemoryFileBoundary _boundary;
  final MemoryMutationCoordinator _mutations;
  final ConfirmationTokenFactory _tokenFactory;
  final MemoryUpdateProposalAuthority _proposals;
  final String _locationId;
  final AppLogger _logger;

  MemoryUpdateProposalAuthority get proposalAuthority => _proposals;

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
    final token = _tokenFactory();
    final diff = _buildDiff(fileName, current ?? '', proposedContent);
    final createdAt = DateTime.now().toUtc();
    await _proposals.issue(
      token,
      _binding(
        fileName: fileName,
        proposedContent: proposedContent,
        diff: diff,
        version: version,
        createdAt: createdAt,
      ),
    );
    return MemoryUpdatePreview(
      fileName: fileName,
      proposedContent: proposedContent,
      diff: diff,
      confirmationToken: token,
      version: version,
      createdAt: createdAt,
      isCreate: isCreate,
    );
  }

  Future<MemoryUpdateResult> apply({
    required String fileName,
    required String proposedContent,
    required String diff,
    required String confirmationToken,
    required String version,
    required DateTime createdAt,
  }) => _applyAuthorized(
    confirmationToken,
    fileName: fileName,
    proposedContent: proposedContent,
    diff: diff,
    version: version,
    createdAt: createdAt,
  );

  Future<void> recover() => _mutations.recover();

  Future<void> recoverProposals() => _proposals.recoverApplying();

  Future<void> revokeProposal(String confirmationToken) =>
      _proposals.revoke(confirmationToken);

  Future<MemoryUpdateResult> applyPersisted({
    required String fileName,
    required String proposedContent,
    required String diff,
    required String confirmationToken,
    required String version,
    required DateTime createdAt,
  }) => _applyAuthorized(
    confirmationToken,
    fileName: fileName,
    proposedContent: proposedContent,
    diff: diff,
    version: version,
    createdAt: createdAt,
  );

  Future<MemoryUpdateResult> _applyAuthorized(
    String confirmationToken, {
    required String fileName,
    required String proposedContent,
    required String diff,
    required String version,
    required DateTime createdAt,
  }) async {
    final stopwatch = Stopwatch()..start();
    _logger.log(event: 'memory.apply', status: 'started');
    var claimed = false;
    try {
      if (confirmationToken.isEmpty) {
        throw const UnknownMemoryConfirmationException();
      }
      final claim = await _proposals.claim(confirmationToken);
      final binding = switch (claim) {
        MemoryProposalClaimed(:final binding) => binding,
        MemoryProposalAlreadyApplied(:final binding) => binding,
      };
      claimed = claim is MemoryProposalClaimed;
      _validate(fileName);
      if (binding.locationId != _locationId ||
          binding.fileName != fileName ||
          binding.contentHash != checksum(proposedContent) ||
          binding.diffHash != checksum(diff) ||
          binding.version != version ||
          createdAt.toUtc() != binding.createdAt.toUtc()) {
        throw const UnknownMemoryConfirmationException();
      }
      if (claim case MemoryProposalAlreadyApplied(:final result)) {
        return MemoryUpdateResult(
          fileName: binding.fileName,
          previousVersion: result.previousVersion,
          version: result.version,
        );
      }
      final current = await _mutations.readIfExists(fileName);
      final proposedVersion = checksum(proposedContent);
      if (current != null && checksum(current) == proposedVersion) {
        final result = MemoryUpdateResult(
          fileName: fileName,
          previousVersion: version,
          version: proposedVersion,
        );
        _logger.log(
          event: 'memory.apply',
          fileName: fileName,
          status: 'already_applied',
          duration: stopwatch.elapsed,
        );
        await _proposals.complete(
          confirmationToken,
          MemoryProposalApplyResult(
            previousVersion: result.previousVersion,
            version: result.version,
          ),
        );
        return result;
      }
      final isCreate = version == missingVersion;
      try {
        await _mutations.mutate(
          event: 'update_memory_file',
          replacements: {fileName: proposedContent},
          expectedVersions: isCreate ? const {} : {fileName: version},
          createIfMissing: isCreate ? {fileName} : const {},
        );
      } on StaleMemoryMutationException {
        throw const StaleMemoryPreviewException();
      } on MemoryMutationException catch (error) {
        throw MemoryAuditException(
          error.cause,
          rollbackSucceeded: error.rollbackSucceeded,
        );
      }
      final result = MemoryUpdateResult(
        fileName: fileName,
        previousVersion: version,
        version: proposedVersion,
      );
      await _proposals.complete(
        confirmationToken,
        MemoryProposalApplyResult(
          previousVersion: result.previousVersion,
          version: result.version,
        ),
      );
      _logger.log(
        event: 'memory.apply',
        fileName: fileName,
        status: 'succeeded',
        duration: stopwatch.elapsed,
      );
      return result;
    } on Object catch (error) {
      _logger.log(
        event: 'memory.apply',
        level: AppLogLevel.error,
        fileName: fileName,
        status: 'failed',
        error: error,
        duration: stopwatch.elapsed,
      );
      if (claimed) await _proposals.release(confirmationToken);
      rethrow;
    }
  }

  MemoryProposalBinding _binding({
    required String fileName,
    required String proposedContent,
    required String diff,
    required String version,
    required DateTime createdAt,
  }) => MemoryProposalBinding(
    fileName: fileName,
    contentHash: checksum(proposedContent),
    diffHash: checksum(diff),
    version: version,
    locationId: _locationId,
    createdAt: createdAt,
  );

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
    required this.createdAt,
    this.isCreate = false,
  });
  final String fileName;
  final String proposedContent;
  final String diff;
  final String confirmationToken;
  final String version;
  final DateTime createdAt;
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
