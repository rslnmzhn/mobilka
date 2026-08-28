import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/presentation/chat_edge_swipe_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<({int history, int artifacts})> swipe(
    WidgetTester tester, {
    required Offset start,
    required Offset delta,
    bool canPresent = true,
    EdgeInsets systemInsets = const EdgeInsets.only(left: 20, right: 24),
    int moves = 1,
  }) async {
    var history = 0;
    var artifacts = 0;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          size: const Size(320, 640),
          systemGestureInsets: systemInsets,
        ),
        child: MaterialApp(
          home: Scaffold(
            body: ChatEdgeSwipeAccess(
              canPresent: () => canPresent,
              onHistory: () => history++,
              onArtifacts: () => artifacts++,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(start);
    for (var index = 1; index <= moves; index++) {
      await gesture.moveTo(start + delta * (index / moves));
    }
    await gesture.up();
    await tester.pump();
    return (history: history, artifacts: artifacts);
  }

  testWidgets('inner left band opens history once', (tester) async {
    final result = await swipe(
      tester,
      start: const Offset(30, 300),
      delta: const Offset(120, 8),
      moves: 3,
    );
    expect(result.history, 1);
    expect(result.artifacts, 0);
  });

  testWidgets('inner right band opens artifacts once', (tester) async {
    final result = await swipe(
      tester,
      start: const Offset(286, 300),
      delta: const Offset(-120, 5),
      moves: 3,
    );
    expect(result.history, 0);
    expect(result.artifacts, 1);
  });

  testWidgets('outer system edge and wrong region do nothing', (tester) async {
    final outer = await swipe(
      tester,
      start: const Offset(5, 300),
      delta: const Offset(120, 0),
    );
    final middle = await swipe(
      tester,
      start: const Offset(100, 300),
      delta: const Offset(120, 0),
    );
    expect(outer, (history: 0, artifacts: 0));
    expect(middle, (history: 0, artifacts: 0));
  });

  testWidgets('vertical diagonal and reversed drags do nothing', (
    tester,
  ) async {
    final vertical = await swipe(
      tester,
      start: const Offset(30, 200),
      delta: const Offset(20, 140),
    );
    final diagonal = await swipe(
      tester,
      start: const Offset(286, 200),
      delta: const Offset(-90, 80),
    );
    final reversed = await swipe(
      tester,
      start: const Offset(30, 200),
      delta: const Offset(-100, 0),
    );
    expect(vertical, (history: 0, artifacts: 0));
    expect(diagonal, (history: 0, artifacts: 0));
    expect(reversed, (history: 0, artifacts: 0));
  });

  testWidgets('route guard suppresses presentation', (tester) async {
    final result = await swipe(
      tester,
      start: const Offset(30, 300),
      delta: const Offset(120, 0),
      canPresent: false,
      moves: 3,
    );
    expect(result, (history: 0, artifacts: 0));
  });

  testWidgets('wrong first decisive movement permanently rejects gesture', (
    tester,
  ) async {
    for (final first in const [Offset(4, 30), Offset(25, 22), Offset(-25, 0)]) {
      var history = 0;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            systemGestureInsets: EdgeInsets.only(left: 20, right: 24),
          ),
          child: MaterialApp(
            home: ChatEdgeSwipeAccess(
              canPresent: () => true,
              onHistory: () => history++,
              onArtifacts: () {},
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      const start = Offset(30, 200);
      final gesture = await tester.startGesture(start);
      await gesture.moveTo(start + first);
      await gesture.moveTo(start + const Offset(120, 0));
      await gesture.up();
      expect(history, 0);
    }
  });
}
