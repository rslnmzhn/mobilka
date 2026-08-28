import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/presentation/chat_message_widgets.dart';

void main() {
  testWidgets(
    'reconstructed pending proposal appears and confirm is single-flight',
    (tester) async {
      final pending = Completer<void>();
      var confirms = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PendingToolProposalCard(
              toolName: 'write_skill',
              isBusy: false,
              onConfirm: () {
                confirms++;
                return pending.future;
              },
              onReject: () async {},
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('pending-tool-proposal')), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-tool-proposal')));
      await tester.tap(find.byKey(const Key('confirm-tool-proposal')));
      expect(confirms, 1);
      pending.complete();
      await tester.pump();
    },
  );

  testWidgets('reject invokes only reject action', (tester) async {
    var confirms = 0;
    var rejects = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PendingToolProposalCard(
            toolName: 'write_skill',
            isBusy: false,
            onConfirm: () async => confirms++,
            onReject: () async => rejects++,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('reject-tool-proposal')));
    await tester.pump();
    expect(rejects, 1);
    expect(confirms, 0);
  });
}
