import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/presentation/chat_navigation_swipe_access.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required bool eligible,
    required VoidCallback onShow,
  }) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatNavigationSwipeAccess(
            isEligible: () => eligible,
            onShowNavigation: onShow,
            child: const SizedBox.expand(
              child: ColoredBox(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('committed center upward touch opens once when eligible', (
    tester,
  ) async {
    var shows = 0;
    await pump(tester, eligible: true, onShow: () => shows++);
    const start = Offset(160, 300);
    final gesture = await tester.startGesture(start);
    for (var index = 1; index <= 3; index++) {
      await gesture.moveTo(start + Offset(0, -100 * index / 3));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await gesture.up();
    await tester.pump();
    expect(shows, 1);
  });

  testWidgets('older position, outer bands, horizontal and reversal reject', (
    tester,
  ) async {
    var shows = 0;
    await pump(tester, eligible: false, onShow: () => shows++);
    await tester.dragFrom(const Offset(160, 380), const Offset(0, -110));
    await pump(tester, eligible: true, onShow: () => shows++);
    await tester.dragFrom(const Offset(12, 380), const Offset(0, -110));
    await tester.dragFrom(const Offset(160, 380), const Offset(110, -20));
    final reversal = await tester.startGesture(const Offset(160, 380));
    await reversal.moveBy(const Offset(0, -45));
    await reversal.moveBy(const Offset(0, 30));
    await reversal.moveBy(const Offset(0, -100));
    await reversal.up();
    expect(shows, 0);
  });

  testWidgets('long hold and second pointer reject', (tester) async {
    var shows = 0;
    await pump(tester, eligible: true, onShow: () => shows++);
    final held = await tester.startGesture(const Offset(160, 380), pointer: 1);
    await tester.pump(const Duration(milliseconds: 500));
    await held.moveBy(const Offset(0, -110));
    await held.up();
    final first = await tester.startGesture(const Offset(160, 380), pointer: 2);
    final second = await tester.startGesture(
      const Offset(170, 370),
      pointer: 3,
    );
    await first.moveBy(const Offset(0, -110));
    await first.up();
    await second.up();
    expect(shows, 0);
  });
}
