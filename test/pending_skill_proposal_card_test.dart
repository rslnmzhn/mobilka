import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/presentation/pending_skill_proposal_card.dart';

void main() {
  testWidgets('action failures are caught and shown safely', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PendingSkillProposalCard(
            name: 'safe',
            oldContent: null,
            proposedContent: '# content',
            sourceDerived: false,
            warningCount: 0,
            isBusy: false,
            onConfirm: () => Future<void>.error(StateError('secret detail')),
            onReject: () async {},
          ),
        ),
      ),
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(find.byKey(const Key('skill-proposal-error')), findsOneWidget);
    expect(find.textContaining('secret detail'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirmation is single flight', (tester) async {
    final pending = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PendingSkillProposalCard(
            name: 'safe',
            oldContent: null,
            proposedContent: '# content',
            sourceDerived: false,
            warningCount: 0,
            isBusy: false,
            onConfirm: () {
              calls++;
              return pending.future;
            },
            onReject: () async {},
          ),
        ),
      ),
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.tap(find.byType(FilledButton), warnIfMissed: false);
    expect(calls, 1);
    pending.complete();
    await tester.pump();
  });
}
