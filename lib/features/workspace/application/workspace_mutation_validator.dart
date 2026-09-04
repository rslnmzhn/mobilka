import 'dart:convert';

import '../domain/workspace_models.dart';
import '../domain/workspace_operation_identity.dart';

final class WorkspaceMutationValidator {
  const WorkspaceMutationValidator._();

  static void verifyProposal({
    required WorkspaceOperationIdentity proposal,
    required String rootIdentity,
    required String sessionKey,
    required DateTime expiresAt,
    required String claimToken,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(claimToken)) {
      throw StateError('workspace_proposal_not_claimed');
    }
    if (proposal.sessionKey != sessionKey ||
        proposal.rootIdentity != rootIdentity) {
      throw StateError('workspace_binding_changed');
    }
    if (DateTime.now().toUtc().isAfter(expiresAt)) {
      throw StateError('workspace_proposal_expired');
    }
  }

  static void verifyEntry(
    WorkspaceEntry? current,
    String? identity,
    String? hash,
    String? type, {
    required bool missing,
  }) {
    if (missing) {
      if (current != null) throw StateError('workspace_target_changed');
      return;
    }
    if (current == null ||
        current.identity != identity ||
        current.sha256 != hash ||
        current.type.name != type) {
      throw StateError('workspace_target_changed');
    }
  }

  static void verifyQuota(
    List<WorkspaceEntry> entries,
    WorkspaceOperationIdentity proposal,
    WorkspaceEntry? source,
    String? proposedContent,
  ) {
    final quotaEntries = entries.where(
      (entry) => entry.path.split('/').first.toLowerCase() != 'artifacts',
    );
    var bytes = 0;
    for (final entry in quotaEntries) {
      final size = entry.size;
      if (size == null) throw StateError('workspace_metadata_unavailable');
      bytes += size;
    }
    final count = quotaEntries.length;
    if (count > workspaceMaxEntries || bytes > workspaceMaxAggregateBytes) {
      throw StateError('workspace_quota_corrupt');
    }
    final countDelta = switch (proposal.operation) {
      'write_file' || 'apply_patch' => source == null ? 1 : 0,
      'make_directory' => 1,
      'delete_file' => -1,
      _ => 0,
    };
    final byteDelta = switch (proposal.operation) {
      'write_file' || 'apply_patch' =>
        utf8.encode(proposedContent!).length - (source?.size ?? 0),
      'delete_file' => -(source?.size ?? 0),
      _ => 0,
    };
    if (count + countDelta > workspaceMaxEntries) {
      throw StateError('workspace_entry_quota_exceeded');
    }
    if (bytes + byteDelta > workspaceMaxAggregateBytes) {
      throw StateError('workspace_byte_quota_exceeded');
    }
  }
}
