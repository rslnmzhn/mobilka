import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/presentation/chat_composer.dart';

void main() {
  late TextEditingController controller;

  setUp(() {
    controller = TextEditingController(text: 'Hello');
  });

  tearDown(() {
    controller.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> pumpComposer(
    WidgetTester tester, {
    required bool isStreaming,
    required bool canSend,
    required void Function(String, List<ChatAttachment>) onSend,
    required VoidCallback onCancel,
    AttachmentPicker? pickAttachment,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            controller: controller,
            isStreaming: isStreaming,
            canSend: canSend,
            onSend: onSend,
            pickAttachment: pickAttachment,
            onCancel: onCancel,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
  }

  testWidgets('Enter sends from a physical keyboard', (tester) async {
    var sends = 0;
    await pumpComposer(
      tester,
      isStreaming: false,
      canSend: true,
      onSend: (_, _) => sends++,
      onCancel: () {},
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);

    expect(sends, 1);
    expect(controller.text, 'Hello');
  });

  testWidgets('Shift+Enter inserts a newline without sending', (tester) async {
    var sends = 0;
    controller.selection = const TextSelection.collapsed(offset: 5);
    await pumpComposer(
      tester,
      isStreaming: false,
      canSend: true,
      onSend: (_, _) => sends++,
      onCancel: () {},
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(sends, 0);
    expect(controller.text, 'Hello\n');
  });

  testWidgets('Enter does not cancel an active stream', (tester) async {
    var sends = 0;
    var cancels = 0;
    await pumpComposer(
      tester,
      isStreaming: true,
      canSend: false,
      onSend: (_, _) => sends++,
      onCancel: () => cancels++,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);

    expect(sends, 0);
    expect(cancels, 0);
    await tester.tap(find.byIcon(Icons.stop));
    expect(cancels, 1);
  });

  testWidgets('mobile composer exposes the send keyboard action', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpComposer(
      tester,
      isStreaming: false,
      canSend: true,
      onSend: (_, _) {},
      onCancel: () {},
    );

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.textInputAction, TextInputAction.send);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('picked attachments appear as chips and reach onSend', (
    tester,
  ) async {
    ChatAttachment? picked;
    final sends = <(String, List<ChatAttachment>)>[];
    await pumpComposer(
      tester,
      isStreaming: false,
      canSend: true,
      onSend: (text, attachments) => sends.add((text, attachments)),
      onCancel: () {},
      pickAttachment: ({required bool image}) async {
        final attachment = ChatAttachment(
          name: image ? 'shot.png' : 'notes.md',
          mimeType: image ? 'image/png' : 'text/markdown',
          dataBase64: base64Encode(utf8.encode('# note')),
        );
        picked = attachment;
        return attachment;
      },
    );

    await tester.tap(find.byKey(const Key('attachment-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attach-image')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('attachment-chip-0')), findsOneWidget);
    expect(picked?.name, 'shot.png');

    await tester.tap(find.byKey(const Key('attachment-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attach-document')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('attachment-chip-1')), findsOneWidget);

    // Remove the first chip via its delete glyph.
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'See files');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();

    expect(sends, hasLength(1));
    expect(sends.single.$1, 'See files');
    expect(sends.single.$2.single.name, 'notes.md');
    // Text clearing is owned by the embedding screen, not the composer.
    expect(controller.text, 'See files');
    expect(find.byKey(const Key('attachment-chip-0')), findsNothing);
  });
}
