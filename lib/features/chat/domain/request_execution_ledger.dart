enum ToolOutcomeTrust {
  trustedLocal,
  publicSource,
  untrustedLocal,
  unknown;

  static ToolOutcomeTrust fromJson(Object? value) {
    if (value is! String) return ToolOutcomeTrust.unknown;
    for (final trust in values) {
      if (trust.name == value) return trust;
    }
    return ToolOutcomeTrust.unknown;
  }
}

class ToolExecutionLedgerEntry {
  const ToolExecutionLedgerEntry({
    required this.requestId,
    required this.toolName,
    required this.succeeded,
    required this.trust,
  });
  final String requestId;
  final String toolName;
  final bool succeeded;
  final ToolOutcomeTrust trust;

  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'toolName': toolName,
    'succeeded': succeeded,
    'trust': trust.name,
  };

  factory ToolExecutionLedgerEntry.fromJson(Map<dynamic, dynamic> json) =>
      ToolExecutionLedgerEntry(
        requestId: json['requestId'].toString(),
        toolName: json['toolName'].toString(),
        succeeded: json['succeeded'] == true,
        trust: ToolOutcomeTrust.fromJson(json['trust']),
      );

  bool hasSameContent(ToolExecutionLedgerEntry other) =>
      requestId == other.requestId &&
      toolName == other.toolName &&
      succeeded == other.succeeded &&
      trust == other.trust;
}

class RequestExecutionLedger {
  const RequestExecutionLedger({
    required this.requestId,
    required this.entries,
    this.hadUntrustedOrUnknown = false,
  });
  static const maxEntries = 32;
  static const maxDecodedEntriesToInspect = 256;
  final String requestId;
  final List<ToolExecutionLedgerEntry> entries;
  final bool hadUntrustedOrUnknown;

  RequestExecutionLedger append(ToolExecutionLedgerEntry entry) {
    if (entry.requestId != requestId) {
      throw StateError('Ledger request changed');
    }
    final all = [...entries, entry];
    final discarded = all.length > maxEntries
        ? all.take(all.length - maxEntries)
        : const <ToolExecutionLedgerEntry>[];
    return RequestExecutionLedger(
      requestId: requestId,
      entries: List.unmodifiable(
        all.skip(all.length > maxEntries ? all.length - maxEntries : 0),
      ),
      hadUntrustedOrUnknown: hadUntrustedOrUnknown || discarded.any(_untrusted),
    );
  }

  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'entries': entries.map((entry) => entry.toJson()).toList(),
    'hadUntrustedOrUnknown': hadUntrustedOrUnknown,
  };

  bool hasSameContent(RequestExecutionLedger other) {
    if (requestId != other.requestId ||
        hadUntrustedOrUnknown != other.hadUntrustedOrUnknown ||
        entries.length != other.entries.length) {
      return false;
    }
    for (var index = 0; index < entries.length; index++) {
      if (!entries[index].hasSameContent(other.entries[index])) return false;
    }
    return true;
  }

  factory RequestExecutionLedger.fromJson(Map<dynamic, dynamic> json) {
    final requestId = json['requestId'] is String
        ? json['requestId'] as String
        : '';
    final raw = json['entries'];
    if (raw is! List) {
      return RequestExecutionLedger(
        requestId: requestId,
        entries: const [],
        hadUntrustedOrUnknown:
            json['hadUntrustedOrUnknown'] == true || raw != null,
      );
    }
    var sticky = json['hadUntrustedOrUnknown'] == true;
    final parsed = <ToolExecutionLedgerEntry>[];
    if (raw.length > maxDecodedEntriesToInspect) sticky = true;
    final start = raw.length > maxDecodedEntriesToInspect
        ? raw.length - maxEntries
        : 0;
    for (var index = start; index < raw.length; index++) {
      final value = raw[index];
      if (value is! Map) {
        sticky = true;
        continue;
      }
      final malformed =
          value['requestId'] is! String ||
          value['toolName'] is! String ||
          value['succeeded'] is! bool ||
          value['trust'] is! String;
      if (malformed) sticky = true;
      final entry = ToolExecutionLedgerEntry.fromJson(value);
      if (entry.requestId != requestId) {
        sticky = true;
        continue;
      }
      parsed.add(entry);
    }
    final discardedCount = parsed.length > maxEntries
        ? parsed.length - maxEntries
        : 0;
    if (parsed.take(discardedCount).any(_untrusted)) sticky = true;
    return RequestExecutionLedger(
      requestId: requestId,
      entries: List.unmodifiable(parsed.skip(discardedCount)),
      hadUntrustedOrUnknown: sticky,
    );
  }

  static bool _untrusted(ToolExecutionLedgerEntry entry) =>
      entry.succeeded && entry.trust != ToolOutcomeTrust.trustedLocal;
}
