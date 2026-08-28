import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/artifacts/presentation/session_artifacts_screen.dart';
import 'package:mobilka/features/artifacts/application/artifacts_controller.dart';
import 'package:mobilka/features/artifacts/domain/artifact.dart';
import 'package:mobilka/features/chat/application/chat_controller.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';

void main() {
  testWidgets(
    'loading resolves exact route id and active changes do not retarget',
    (tester) async {
      final controller = _FakeChatController(const AsyncLoading());
      await _pump(tester, controller, 'a');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      controller.publish(_state([_conversation('a'), _conversation('b')], 'b'));
      await tester.pump();
      expect(
        find.byKey(const Key('session-artifacts-unavailable')),
        findsNothing,
      );
      controller.publish(_state([_conversation('a'), _conversation('b')], 'a'));
      await tester.pump();
      expect(
        find.byKey(const Key('session-artifacts-unavailable')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'missing and duplicate IDs fail closed without document creation',
    (tester) async {
      final controller = _FakeChatController(
        AsyncData(_state([_conversation('b')], 'b')),
      );
      await _pump(tester, controller, 'a');
      expect(
        find.byKey(const Key('session-artifacts-unavailable')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('artifact-create')), findsNothing);

      controller.publish(_state([_conversation('a'), _conversation('a')], 'a'));
      await tester.pump();
      expect(
        find.byKey(const Key('session-artifacts-unavailable')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('artifact-documents')), findsNothing);
    },
  );

  testWidgets('back arrow and framework pop return to underlying route', (
    tester,
  ) async {
    final controller = _FakeChatController(
      AsyncData(_state([_conversation('a')], 'a')),
    );
    await _pump(tester, controller, 'a');
    await tester.tap(find.byKey(const Key('session-artifacts-back')));
    await tester.pumpAndSettle();
    expect(find.text('underlying'), findsOneWidget);

    await _pushAgain(tester, 'a');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('underlying'), findsOneWidget);
  });

  testWidgets('tab zero broad center swipe pops; conflicts do not', (
    tester,
  ) async {
    final controller = _FakeChatController(
      AsyncData(_state([_conversation('a')], 'a')),
    );
    await _pump(tester, controller, 'a');
    await tester.dragFrom(const Offset(150, 400), const Offset(130, 2));
    await tester.pumpAndSettle();
    expect(find.text('underlying'), findsOneWidget);

    await _pushAgain(tester, 'a');
    await tester.dragFrom(const Offset(150, 400), const Offset(0, 150));
    await tester.pumpAndSettle();
    expect(find.byType(SessionArtifactsScreen), findsOneWidget);
    final cancelled = await tester.startGesture(const Offset(150, 400));
    await cancelled.moveBy(const Offset(20, 0));
    await cancelled.cancel();
    await tester.pumpAndSettle();
    expect(find.byType(SessionArtifactsScreen), findsOneWidget);
    await tester.dragFrom(const Offset(200, 400), const Offset(-130, 0));
    await tester.pumpAndSettle();
    expect(find.byType(SessionArtifactsScreen), findsOneWidget);

    await tester.drag(find.byType(TabBar).first, const Offset(-180, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('artifacts.documents'));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(150, 400), const Offset(130, 0));
    await tester.pumpAndSettle();
    expect(find.byType(SessionArtifactsScreen), findsOneWidget);
  });
}

Future<void> _pump(
  WidgetTester tester,
  _FakeChatController controller,
  String id,
) async {
  await tester.binding.setSurfaceSize(const Size(320, 720));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        chatControllerProvider.overrideWith(() => controller),
        artifactsControllerProvider.overrideWith(_EmptyArtifactsController.new),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SessionArtifactsScreen(conversationId: id),
                  ),
                ),
                child: const Text('underlying'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _pushAgain(tester, id);
}

Future<void> _pushAgain(WidgetTester tester, String id) async {
  final context = tester.element(find.text('underlying'));
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SessionArtifactsScreen(conversationId: id),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

ChatState _state(List<Conversation> conversations, String active) =>
    ChatState(conversations: conversations, activeConversationId: active);

Conversation _conversation(String id) => Conversation(
  id: id,
  title: id,
  modelId: 'model',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  messages: const [],
  sessionKey: 'session-$id',
);

class _FakeChatController extends ChatController {
  _FakeChatController(this.initial);
  final AsyncValue<ChatState> initial;

  @override
  Future<ChatState> build() => initial.when(
    data: Future<ChatState>.value,
    loading: () => Completer<ChatState>().future,
    error: (error, stack) => Future<ChatState>.error(error, stack),
  );

  void publish(ChatState value) => state = AsyncData(value);
}

class _EmptyArtifactsController extends ArtifactsController {
  @override
  List<Artifact> build() => const [];
}
