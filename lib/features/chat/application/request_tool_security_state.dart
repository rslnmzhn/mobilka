import '../domain/request_execution_ledger.dart';

class SkillLearningProvenance {
  const SkillLearningProvenance._({
    required this.conversationId,
    required this.ledger,
  });
  final String conversationId;
  final RequestExecutionLedger ledger;
  String get requestId => ledger.requestId;
  List<ToolExecutionLedgerEntry> get entries => ledger.entries;
  bool get sourceDerived =>
      ledger.hadUntrustedOrUnknown ||
      entries.any(
        (entry) =>
            entry.succeeded &&
            (entry.trust == ToolOutcomeTrust.publicSource ||
                entry.trust == ToolOutcomeTrust.untrustedLocal),
      );
  bool get hasQualifyingSuccess => entries.any(
    (entry) =>
        entry.succeeded &&
        entry.trust == ToolOutcomeTrust.trustedLocal &&
        deterministicEvidenceTools.contains(entry.toolName),
  );
  bool get allowsAutomaticCreate =>
      !ledger.hadUntrustedOrUnknown &&
      hasQualifyingSuccess &&
      entries.every(
        (entry) =>
            !entry.succeeded || entry.trust == ToolOutcomeTrust.trustedLocal,
      );
  static const deterministicEvidenceTools = {
    'get_current_time',
    'list_session_files',
    'read_session_notes',
    'material_tool',
  };
  String get summary => [
    if (ledger.hadUntrustedOrUnknown) 'discarded:unknown',
    ...entries.map(
      (entry) =>
          '${entry.toolName}:${entry.succeeded ? 'ok' : 'failed'}:${entry.trust.name}',
    ),
  ].join(',');
}

class RequestToolSecurityState {
  RequestToolSecurityState({
    required this.conversationId,
    required this.requestId,
    required RequestExecutionLedger Function() readLedger,
    required Future<RequestExecutionLedger> Function(
      ToolExecutionLedgerEntry entry,
    )
    appendLedgerEntry,
  }) : _readLedger = readLedger,
       _appendLedgerEntry = appendLedgerEntry,
       _lastAuthoritative = _forRequest(readLedger(), requestId);
  final String conversationId;
  final String requestId;
  final RequestExecutionLedger Function() _readLedger;
  final Future<RequestExecutionLedger> Function(ToolExecutionLedgerEntry entry)
  _appendLedgerEntry;
  RequestExecutionLedger _lastAuthoritative;
  Future<void> _appendTail = Future.value();
  bool _reflectionAttempted = false;
  bool get sourceTainted => currentSnapshot().sourceDerived;

  Future<void> recordOutcome({
    required String toolName,
    required bool succeeded,
  }) async {
    final trust = switch (toolName) {
      'read_public_source' || 'web_search' => ToolOutcomeTrust.publicSource,
      'read_skill' => ToolOutcomeTrust.untrustedLocal,
      'list_skills' ||
      'write_skill' ||
      'propose_skill' => ToolOutcomeTrust.unknown,
      'get_current_time' ||
      'list_session_files' ||
      'read_session_notes' ||
      'material_tool' => ToolOutcomeTrust.trustedLocal,
      _ => ToolOutcomeTrust.unknown,
    };
    final entry = ToolExecutionLedgerEntry(
      requestId: requestId,
      toolName: toolName,
      succeeded: succeeded,
      trust: trust,
    );
    final operation = _appendTail.then((_) async {
      _lastAuthoritative = await _appendLedgerEntry(entry);
    });
    _appendTail = operation;
    await operation;
  }

  SkillLearningProvenance currentSnapshot() => SkillLearningProvenance._(
    conversationId: conversationId,
    ledger: _normalizedCurrent(),
  );

  SkillLearningProvenance verifiedSnapshot() {
    final current = _normalizedCurrent();
    if (!current.hasSameContent(_lastAuthoritative)) {
      throw StateError('Persisted request ledger mismatch');
    }
    return SkillLearningProvenance._(
      conversationId: conversationId,
      ledger: current,
    );
  }

  RequestExecutionLedger _normalizedCurrent() {
    return _forRequest(_readLedger(), requestId);
  }

  bool claimReflection() {
    if (_reflectionAttempted) return false;
    _reflectionAttempted = true;
    return true;
  }
}

RequestExecutionLedger _forRequest(
  RequestExecutionLedger ledger,
  String requestId,
) => ledger.requestId == requestId
    ? ledger
    : RequestExecutionLedger(requestId: requestId, entries: const []);
