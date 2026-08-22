import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/presentation/chat_screen.dart';

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
    required VoidCallback onSend,
    required VoidCallback onCancel,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            controller: controller,
            isStreaming: isStreaming,
            canSend: canSend,
            onSend: onSend,
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
      onSend: () => sends++,
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
      onSend: () => sends++,
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
      onSend: () => sends++,
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
      onSend: () {},
      onCancel: () {},
    );

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.textInputAction, TextInputAction.send);
    debugDefaultTargetPlatformOverride = null;
  });
}
