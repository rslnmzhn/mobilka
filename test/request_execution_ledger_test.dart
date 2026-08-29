import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/request_tool_security_state.dart';
import 'package:mobilka/features/chat/domain/request_execution_ledger.dart';

void main() {
  test('trust decoding is forward compatible and never throws', () {
    expect(
      ToolOutcomeTrust.fromJson('trustedLocal'),
      ToolOutcomeTrust.trustedLocal,
    );
    for (final value in [null, 3, true, 'future_trust']) {
      expect(ToolOutcomeTrust.fromJson(value), ToolOutcomeTrust.unknown);
    }
  });

  test('ledger retains newest 32 and sticky discarded untrusted state', () {
    var ledger = const RequestExecutionLedger(requestId: 'r', entries: []);
    ledger = ledger.append(
      const ToolExecutionLedgerEntry(
        requestId: 'r',
        toolName: 'read_public_source',
        succeeded: true,
        trust: ToolOutcomeTrust.publicSource,
      ),
    );
    for (var index = 0; index < 33; index++) {
      ledger = ledger.append(
        ToolExecutionLedgerEntry(
          requestId: 'r',
          toolName: 'material_tool',
          succeeded: true,
          trust: ToolOutcomeTrust.trustedLocal,
        ),
      );
    }
    expect(ledger.entries, hasLength(32));
    expect(ledger.hadUntrustedOrUnknown, isTrue);
    final restored = RequestExecutionLedger.fromJson(ledger.toJson());
    expect(restored.hadUntrustedOrUnknown, isTrue);
    final state = RequestToolSecurityState(
      conversationId: 'c',
      requestId: 'r',
      readLedger: () => restored,
      appendLedgerEntry: (_) async => restored,
    );
    final provenance = state.currentSnapshot();
    expect(provenance.sourceDerived, isTrue);
    expect(provenance.allowsAutomaticCreate, isFalse);
    expect(provenance.summary, startsWith('discarded:unknown'));
  });

  test('unknown tools are never trusted by default', () {
    var ledger = const RequestExecutionLedger(requestId: 'r', entries: []);
    final state = RequestToolSecurityState(
      conversationId: 'c',
      requestId: 'r',
      readLedger: () => ledger,
      appendLedgerEntry: (entry) async => ledger = ledger.append(entry),
    );
    return state
        .recordOutcome(toolName: 'new_unknown_tool', succeeded: true)
        .then((_) {
          expect(ledger.entries.single.trust, ToolOutcomeTrust.unknown);
          expect(state.currentSnapshot().allowsAutomaticCreate, isFalse);
        });
  });

  test('same request and count with different entries fails closed', () async {
    var ledger = const RequestExecutionLedger(requestId: 'r', entries: []);
    final state = RequestToolSecurityState(
      conversationId: 'c',
      requestId: 'r',
      readLedger: () => ledger,
      appendLedgerEntry: (entry) async => ledger = ledger.append(entry),
    );
    await state.recordOutcome(toolName: 'material_tool', succeeded: true);
    ledger = const RequestExecutionLedger(
      requestId: 'r',
      entries: [
        ToolExecutionLedgerEntry(
          requestId: 'r',
          toolName: 'read_public_source',
          succeeded: true,
          trust: ToolOutcomeTrust.publicSource,
        ),
      ],
    );
    expect(state.verifiedSnapshot, throwsStateError);
  });

  test('concurrent outcomes serialize without losing an entry', () async {
    var ledger = const RequestExecutionLedger(requestId: 'r', entries: []);
    var activeAppends = 0;
    final state = RequestToolSecurityState(
      conversationId: 'c',
      requestId: 'r',
      readLedger: () => ledger,
      appendLedgerEntry: (entry) async {
        activeAppends++;
        expect(activeAppends, 1);
        await Future<void>.delayed(const Duration(milliseconds: 1));
        ledger = ledger.append(entry);
        activeAppends--;
        return ledger;
      },
    );
    await Future.wait([
      state.recordOutcome(toolName: 'material_tool', succeeded: true),
      state.recordOutcome(toolName: 'get_current_time', succeeded: true),
    ]);
    expect(ledger.entries.map((entry) => entry.toolName), [
      'material_tool',
      'get_current_time',
    ]);
    expect(state.verifiedSnapshot().entries, hasLength(2));
  });

  test('restore fails closed for malformed entries and trust values', () {
    final restored = RequestExecutionLedger.fromJson({
      'requestId': 'r',
      'entries': [
        'not-an-entry',
        {
          'requestId': 'r',
          'toolName': 'future',
          'succeeded': true,
          'trust': 'future_trust',
        },
      ],
    });
    expect(restored.hadUntrustedOrUnknown, isTrue);
    expect(restored.entries.single.trust, ToolOutcomeTrust.unknown);
    expect(
      RequestExecutionLedger.fromJson(restored.toJson()).hadUntrustedOrUnknown,
      isTrue,
    );
  });

  test('restore observes early and late taint before retaining newest 32', () {
    Map<String, Object?> entry(int index, ToolOutcomeTrust trust) => {
      'requestId': 'r',
      'toolName': 'tool-$index',
      'succeeded': true,
      'trust': trust.name,
    };
    for (final taintedIndex in [0, 39]) {
      final entries = List.generate(
        40,
        (index) => entry(
          index,
          index == taintedIndex
              ? ToolOutcomeTrust.publicSource
              : ToolOutcomeTrust.trustedLocal,
        ),
      );
      final restored = RequestExecutionLedger.fromJson({
        'requestId': 'r',
        'entries': entries,
      });
      expect(restored.entries, hasLength(32));
      expect(
        restored.hadUntrustedOrUnknown ||
            restored.entries.any(
              (entry) =>
                  entry.succeeded &&
                  entry.trust != ToolOutcomeTrust.trustedLocal,
            ),
        isTrue,
      );
    }
  });

  test('oversized decoded arrays are bounded and fail closed', () {
    final entries = List.generate(
      300,
      (index) => {
        'requestId': 'r',
        'toolName': 'tool-$index',
        'succeeded': true,
        'trust': ToolOutcomeTrust.trustedLocal.name,
      },
    );
    final restored = RequestExecutionLedger.fromJson({
      'requestId': 'r',
      'entries': entries,
    });
    expect(restored.entries, hasLength(32));
    expect(restored.hadUntrustedOrUnknown, isTrue);
  });
}
