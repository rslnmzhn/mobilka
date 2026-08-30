import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/presentation/chat_navigation_swipe_access.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required bool eligible,
    required VoidCallback onShow,
    EdgeInsets systemGestureInsets = EdgeInsets.zero,
  }) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          size: const Size(320, 600),
          systemGestureInsets: systemGestureInsets,
        ),
        child: MaterialApp(
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
      ),
    );
  }

  testWidgets('fourteen pixel slow upward intent reveals immediately once', (
    tester,
  ) async {
    var shows = 0;
    await pump(tester, eligible: true, onShow: () => shows++);
    const start = Offset(160, 300);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(0, -14));
    await tester.pump(const Duration(milliseconds: 100));
    expect(shows, 1);
    await gesture.moveBy(const Offset(0, -6));
    await gesture.up();
    await tester.pump();
    expect(shows, 1);
  });

  testWidgets('thirteen pixel movement does not reveal', (tester) async {
    var shows = 0;
    await pump(tester, eligible: true, onShow: () => shows++);
    final gesture = await tester.startGesture(const Offset(160, 300));
    await gesture.moveBy(const Offset(0, -13));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    expect(shows, 0);
  });

  testWidgets('long and fast upward movement reveals only once', (
    tester,
  ) async {
    var shows = 0;
    await pump(tester, eligible: true, onShow: () => shows++);
    final gesture = await tester.startGesture(const Offset(160, 300));
    await gesture.moveBy(const Offset(0, -120));
    await gesture.moveBy(const Offset(0, -120));
    await gesture.up();
    expect(shows, 1);
  });

  testWidgets('broad horizontal and vertical message-region starts succeed', (
    tester,
  ) async {
    var shows = 0;
    await pump(tester, eligible: true, onShow: () => shows++);
    for (final start in const [
      Offset(20, 40),
      Offset(300, 300),
      Offset(20, 560),
    ]) {
      await tester.dragFrom(start, const Offset(0, -100));
    }
    expect(shows, 3);
  });

  testWidgets('sixteen px plus system gesture edges are excluded', (
    tester,
  ) async {
    var shows = 0;
    await pump(
      tester,
      eligible: true,
      onShow: () => shows++,
      systemGestureInsets: const EdgeInsets.only(left: 20, right: 24),
    );
    await tester.dragFrom(const Offset(19, 300), const Offset(0, -100));
    await tester.dragFrom(const Offset(297, 300), const Offset(0, -100));
    await tester.dragFrom(const Offset(21, 300), const Offset(0, -100));
    await tester.dragFrom(const Offset(295, 300), const Offset(0, -100));
    expect(shows, 2);
  });

  testWidgets('older position, system edges, down and horizontal reject', (
    tester,
  ) async {
    var shows = 0;
    await pump(tester, eligible: false, onShow: () => shows++);
    await tester.dragFrom(const Offset(160, 380), const Offset(0, -110));
    await pump(tester, eligible: true, onShow: () => shows++);
    await tester.dragFrom(const Offset(8, 380), const Offset(0, -110));
    await tester.dragFrom(const Offset(160, 380), const Offset(110, -20));
    await tester.dragFrom(const Offset(160, 380), const Offset(0, 110));
    expect(shows, 0);
  });

  testWidgets('reversal after reveal does not duplicate action', (
    tester,
  ) async {
    var shows = 0;
    await pump(tester, eligible: true, onShow: () => shows++);
    final reversal = await tester.startGesture(const Offset(160, 380));
    await reversal.moveBy(const Offset(0, -14));
    expect(shows, 1);
    await reversal.moveBy(const Offset(0, 30));
    await reversal.moveBy(const Offset(0, -100));
    await reversal.up();
    expect(shows, 1);
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
