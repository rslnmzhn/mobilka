import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/shell/presentation/app_shell.dart';

void main() {
  testWidgets('chat dock footprint and slide animate from zero to 52', (
    tester,
  ) async {
    final visible = ValueNotifier(false);
    addTearDown(visible.dispose);
    await _pumpHost(tester, visible);

    expect(_footprintHeight(tester), 0);
    expect(find.byKey(const Key('animated-chat-dock-slide')), findsNothing);

    visible.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(_footprintHeight(tester), inExclusiveRange(0, 52));
    expect(_slideY(tester), inExclusiveRange(0, 52));

    await tester.pumpAndSettle();
    expect(_footprintHeight(tester), 52);
    expect(_slideY(tester), 0);

    visible.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(_footprintHeight(tester), inExclusiveRange(0, 52));
    expect(_slideY(tester), inExclusiveRange(0, 52));
    await tester.pumpAndSettle();
    expect(_footprintHeight(tester), 0);
    expect(find.byKey(const Key('animated-chat-dock-slide')), findsNothing);
  });

  testWidgets('disableAnimations makes chat dock transition immediate', (
    tester,
  ) async {
    final visible = ValueNotifier(false);
    addTearDown(visible.dispose);
    await _pumpHost(tester, visible, disableAnimations: true);

    visible.value = true;
    await tester.pump();
    expect(_footprintHeight(tester), 52);
    expect(_slideY(tester), 0);

    visible.value = false;
    await tester.pump();
    expect(_footprintHeight(tester), 0);
    expect(find.byKey(const Key('animated-chat-dock-slide')), findsNothing);
  });

  testWidgets('downward drag on visible dock requests animated hide', (
    tester,
  ) async {
    var hides = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: ChatDockHideGesture(
            enabled: true,
            onHide: () => hides++,
            child: const SizedBox(height: 52),
          ),
        ),
      ),
    );

    await tester.drag(find.byType(ChatDockHideGesture), const Offset(0, 30));
    expect(hides, 1);
  });
}

Future<void> _pumpHost(
  WidgetTester tester,
  ValueNotifier<bool> visible, {
  bool disableAnimations = false,
}) => tester.pumpWidget(
  MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(
        bottomNavigationBar: ValueListenableBuilder(
          valueListenable: visible,
          builder: (context, value, _) => AnimatedChatDockHost(
            visible: value,
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    ),
  ),
);

double _footprintHeight(WidgetTester tester) => tester
    .getSize(find.byKey(const Key('animated-chat-dock-footprint')))
    .height;

double _slideY(WidgetTester tester) => tester
    .widget<Transform>(find.byKey(const Key('animated-chat-dock-slide')))
    .transform
    .getTranslation()
    .y;
