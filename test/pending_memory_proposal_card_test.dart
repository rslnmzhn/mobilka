import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/presentation/chat_message_widgets.dart';

void main() {
  testWidgets('confirm is disabled and shows progress while running', (
    tester,
  ) async {
    final confirmation = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PendingMemoryProposalCard(
            fileName: 'user_profile.md',
            diff: '+fact',
            onConfirm: () => confirmation.future,
            onReject: () async {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('confirm-memory-proposal')));
    await tester.pump();

    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('confirm-memory-proposal')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('reject-memory-proposal')))
          .onPressed,
      isNull,
    );
    expect(
      find.byKey(const Key('confirm-memory-proposal-progress')),
      findsOneWidget,
    );

    confirmation.complete();
    await tester.pump();
  });

  testWidgets('confirmation failure is visible and reject remains available', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PendingMemoryProposalCard(
            fileName: 'user_profile.md',
            diff: '+fact',
            onConfirm: () => throw StateError('failed'),
            onReject: () async {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('confirm-memory-proposal')));
    await tester.pump();

    expect(find.byKey(const Key('memory-proposal-error')), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('reject-memory-proposal')))
          .onPressed,
      isNotNull,
    );
  });
}
