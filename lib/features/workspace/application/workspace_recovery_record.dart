import 'dart:convert';
import 'dart:math';

import '../../../core/workspace/workspace_binding.dart';
import '../domain/workspace_mutation_result.dart';
import '../domain/workspace_operation_identity.dart';
import 'session_workspace_boundary.dart';

final class WorkspaceRecoveryPendingException implements Exception {
  const WorkspaceRecoveryPendingException(this.code);
  final String code;
  @override
  String toString() => code;
}

String newWorkspaceRecoveryToken(int byteCount) {
  final random = Random.secure();
  final bytes = List<int>.generate(byteCount, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

final class WorkspaceRecoveryRecord {
  const WorkspaceRecoveryRecord({
    required this.state,
    required this.operation,
    required this.ownerToken,
    required this.claimToken,
    required this.bindingSnapshot,
    required this.createdAt,
    this.prepared,
    this.outcome,
    this.payload,
  });

  final String state;
  final WorkspaceOperationIdentity operation;
  final String ownerToken;
  final String claimToken;
  final WorkspaceBindingSnapshot bindingSnapshot;
  final DateTime createdAt;
  final PreparedWorkspaceMutation? prepared;
  final WorkspaceMutationOutcome? outcome;
  final Map<String, Object?>? payload;

  String get rootIdentity => operation.rootIdentity;
  String get sessionKey => operation.sessionKey;

  WorkspaceMutationResult get result => WorkspaceMutationResult(
    outcome: outcome!,
    payload: payload!,
    operationId: prepared!.operationId,
    token: prepared!.token,
  );

  factory WorkspaceRecoveryRecord.claimed(
    WorkspaceOperationIdentity operation,
    WorkspaceBindingSnapshot bindingSnapshot,
    String claimToken,
    String ownerToken,
  ) => WorkspaceRecoveryRecord(
    state: 'claimed',
    operation: operation,
    ownerToken: ownerToken,
    claimToken: claimToken,
    bindingSnapshot: bindingSnapshot,
    createdAt: DateTime.now().toUtc(),
  );

  factory WorkspaceRecoveryRecord.decode(Object? source) {
    if (source is! Map) throw const FormatException('record_not_map');
    final json = Map<String, Object?>.from(source);
    const keys = {
      'version',
      'state',
      'operation',
      'ownerToken',
      'claimToken',
      'prepared',
      'bindingSnapshot',
      'createdAt',
      'outcome',
      'payload',
    };
    if (json.length != keys.length ||
        !json.keys.toSet().containsAll(keys) ||
        json['version'] != 6 ||
        json['ownerToken'] is! String ||
        json['claimToken'] is! String ||
        !{'claimed', 'prepared', 'terminal'}.contains(json['state'])) {
      throw const FormatException('record_schema');
    }
    final state = json['state']! as String;
    final createdAt = DateTime.tryParse(json['createdAt'] as String? ?? '');
    final rawOperation = json['operation'];
    final rawBinding = json['bindingSnapshot'];
    final rawPrepared = json['prepared'];
    final rawPayload = json['payload'];
    final outcomeName = json['outcome'];
    final outcome = outcomeName is String
        ? WorkspaceMutationOutcome.values
              .where((value) => value.name == outcomeName)
              .firstOrNull
        : null;
    if (createdAt == null ||
        rawOperation is! Map ||
        rawBinding is! Map ||
        (state != 'claimed' && rawPrepared is! Map) ||
        (state == 'claimed' && rawPrepared != null) ||
        (state == 'prepared' && (outcomeName != null || rawPayload != null)) ||
        (state == 'terminal' && (outcome == null || rawPayload is! Map)) ||
        (state != 'terminal' && (outcomeName != null || rawPayload != null))) {
      throw const FormatException('record_schema');
    }
    final operation = WorkspaceOperationIdentity.fromJson(rawOperation);
    final binding = WorkspaceBindingSnapshot.fromJson(rawBinding);
    if (binding.rootIdentity != operation.rootIdentity) {
      throw const FormatException('record_binding');
    }
    return WorkspaceRecoveryRecord(
      state: state,
      operation: operation,
      ownerToken: json['ownerToken']! as String,
      claimToken: json['claimToken']! as String,
      bindingSnapshot: binding,
      createdAt: createdAt.toUtc(),
      prepared: rawPrepared is Map
          ? PreparedWorkspaceMutation.fromJson(rawPrepared)
          : null,
      outcome: outcome,
      payload: rawPayload is Map ? Map<String, Object?>.from(rawPayload) : null,
    );
  }

  static WorkspaceRecoveryInvalidHint? invalidHint(Object? source) {
    if (source is! Map) return null;
    try {
      final rawOperation = source['operation'];
      if (rawOperation is! Map) return null;
      final operation = WorkspaceOperationIdentity.fromJson(rawOperation);
      final state = source['state'];
      final claimToken = source['claimToken'];
      final ownerToken = source['ownerToken'];
      return WorkspaceRecoveryInvalidHint(
        operation: operation,
        ownerToken: ownerToken is String ? ownerToken : null,
        claimToken: claimToken is String ? claimToken : null,
        provablyClaimOnly:
            source['version'] == 6 &&
            state == 'claimed' &&
            ownerToken is String &&
            claimToken is String &&
            RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(claimToken) &&
            source['prepared'] == null &&
            source['outcome'] == null &&
            source['payload'] == null,
      );
    } on Object {
      return null;
    }
  }

  void verifyOperation(
    WorkspaceOperationIdentity value,
    String? token,
    String owner,
  ) {
    if (operation != value || claimToken != token || ownerToken != owner) {
      throw const FormatException('proposal_changed');
    }
  }

  WorkspaceRecoveryRecord preparedWith(PreparedWorkspaceMutation value) =>
      _copy(state: 'prepared', prepared: value);

  WorkspaceRecoveryRecord terminal(WorkspaceMutationResult value) => _copy(
    state: 'terminal',
    prepared: prepared,
    outcome: value.outcome,
    payload: value.payload,
  );

  WorkspaceRecoveryRecord _copy({
    required String state,
    required PreparedWorkspaceMutation? prepared,
    WorkspaceMutationOutcome? outcome,
    Map<String, Object?>? payload,
  }) => WorkspaceRecoveryRecord(
    state: state,
    operation: operation,
    ownerToken: ownerToken,
    claimToken: claimToken,
    bindingSnapshot: bindingSnapshot,
    createdAt: createdAt,
    prepared: prepared,
    outcome: outcome,
    payload: payload,
  );

  Map<String, Object?> toJson() => {
    'version': 6,
    'state': state,
    'operation': operation.toJson(),
    'ownerToken': ownerToken,
    'claimToken': claimToken,
    'prepared': prepared?.toJson(),
    'bindingSnapshot': bindingSnapshot.toJson(),
    'createdAt': createdAt.toIso8601String(),
    'outcome': outcome?.name,
    'payload': payload,
  };
}

final class WorkspaceRecoveryInvalidHint {
  const WorkspaceRecoveryInvalidHint({
    required this.operation,
    required this.ownerToken,
    required this.claimToken,
    required this.provablyClaimOnly,
  });

  final WorkspaceOperationIdentity operation;
  final String? ownerToken;
  final String? claimToken;
  final bool provablyClaimOnly;
}

String workspaceJournalNamespace(String rootIdentity, String sessionKey) =>
    '${base64Url.encode(utf8.encode(rootIdentity))}.'
    '${base64Url.encode(utf8.encode(sessionKey))}.';

String workspaceJournalKey({
  required String rootIdentity,
  required String sessionKey,
  required String operationId,
}) => '${workspaceJournalNamespace(rootIdentity, sessionKey)}$operationId';
