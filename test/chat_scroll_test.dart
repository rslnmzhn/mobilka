import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/chat_controller.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/chat/presentation/chat_screen.dart';
import 'package:mobilka/features/models/application/models_controller.dart';
import 'package:mobilka/features/models/domain/ai_model.dart';
import 'package:mobilka/features/shell/presentation/chat_navigation_controller.dart';
import 'package:mobilka/features/shell/presentation/shell_navigation_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('async restored long chat starts at newest and logical zero', (
    tester,
  ) async {
    final controller = _ChatController.loading();
    await _pump(tester, controller);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    controller.complete(_state([_longConversation('a')], 'a'));
    await tester.pumpAndSettle();

    _expectAtNewest(tester, 'a');
  });

  testWidgets('already loaded long restored chat mounts at newest', (
    tester,
  ) async {
    final controller = _ChatController.data(
      _state([_longConversation('a')], 'a'),
    );
    await _pump(tester, controller);

    _expectAtNewest(tester, 'a');
  });

  testWidgets('conversation switch resets inherited browsing position', (
    tester,
  ) async {
    final a = _longConversation('a');
    final b = _longConversation('b');
    final controller = _ChatController.data(_state([a, b], 'a'));
    await _pump(tester, controller);
    await _browseOlder(tester);

    controller.publish(_state([a, b], 'b'));
    await tester.pumpAndSettle();

    _expectAtNewest(tester, 'b');
  });

  testWidgets('pinned stream growth follows newest message', (tester) async {
    final original = _longConversation('a');
    final controller = _ChatController.data(_state([original], 'a'));
    await _pump(tester, controller);
    final appended = original.copyWith(
      messages: [...original.messages, _message('a-new', 8)],
    );

    controller.publish(_state([appended], 'a'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('a-new')), findsOneWidget);
    expect(_position(tester).pixels, 0);
  });

  testWidgets('browsing is not yanked and user return resumes following', (
    tester,
  ) async {
    var conversation = _longConversation('a');
    final controller = _ChatController.data(_state([conversation], 'a'));
    await _pump(tester, controller);
    await _browseOlder(tester);
    final browsingOffset = _position(tester).pixels;

    controller.publish(
      _state([conversation.copyWith(title: 'Updated title')], 'a'),
    );
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, closeTo(browsingOffset, 1));

    controller.publish(
      _state([conversation], 'a').copyWith(errorMessage: 'non-message update'),
    );
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, closeTo(browsingOffset, 1));

    final last = conversation.messages.last;
    conversation = conversation.copyWith(
      messages: [
        ...conversation.messages.take(conversation.messages.length - 1),
        last.copyWith(content: '${last.content}\n${'stream delta ' * 30}'),
      ],
    );
    controller.publish(_state([conversation], 'a'));
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, greaterThan(80));

    for (
      var attempt = 0;
      attempt < 10 && _position(tester).pixels > 80;
      attempt++
    ) {
      await tester.drag(find.byType(ListView).last, const Offset(0, -500));
      await tester.pumpAndSettle();
    }
    expect(_position(tester).pixels, lessThanOrEqualTo(80));

    conversation = conversation.copyWith(
      messages: [...conversation.messages, _message('followed-new', 4)],
    );
    controller.publish(_state([conversation], 'a'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('followed-new')), findsOneWidget);
    expect(_position(tester).pixels, 0);
  });

  testWidgets('reverse builder preserves visual chronological order', (
    tester,
  ) async {
    final conversation = _conversation('order', [
      _message('oldest', 1),
      _message('middle', 1),
      _message('newest', 1),
    ]);
    await _pump(tester, _ChatController.data(_state([conversation], 'order')));

    expect(
      tester.getTopLeft(find.byKey(const ValueKey('oldest'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('middle'))).dy),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('middle'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('newest'))).dy),
    );
  });

  testWidgets('variable Markdown remains overflow-free at 320 pixels', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final conversation = _conversation('narrow', [
      _message(
        'narrow-message',
        1,
        content:
            '## Heading\n\n`${'long_unbroken_identifier_' * 20}`\n\n'
            '${'> quoted variable-height line\n' * 12}',
      ),
    ]);

    await _pump(
      tester,
      _ChatController.data(_state([conversation], 'narrow')),
      setSize: false,
    );

    expect(find.byKey(const ValueKey('narrow-message')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop mouse wheel browsing unpins until return to bottom', (
    tester,
  ) async {
    var conversation = _longConversation('wheel');
    final controller = _ChatController.data(_state([conversation], 'wheel'));
    await _pump(tester, controller);
    final listCenter = tester.getCenter(find.byType(ListView).last);

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: listCenter,
        scrollDelta: const Offset(0, -500),
      ),
    );
    await tester.pumpAndSettle();
    final browsingOffset = _position(tester).pixels;
    expect(browsingOffset, greaterThan(80));

    conversation = conversation.copyWith(
      messages: [...conversation.messages, _message('wheel-new', 5)],
    );
    controller.publish(_state([conversation], 'wheel'));
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, greaterThan(80));

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: listCenter,
        scrollDelta: const Offset(0, 5000),
      ),
    );
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, lessThanOrEqualTo(80));

    conversation = conversation.copyWith(
      messages: [...conversation.messages, _message('wheel-followed', 2)],
    );
    controller.publish(_state([conversation], 'wheel'));
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, 0);
    expect(find.byKey(const ValueKey('wheel-followed')), findsOneWidget);
  });

  testWidgets('user movement toward older hides nav without consuming scroll', (
    tester,
  ) async {
    final navigation = _visibleNavigation();
    addTearDown(navigation.dispose);
    await _pump(
      tester,
      _ChatController.data(_state([_longConversation('hide')], 'hide')),
      navigation: navigation,
    );

    await tester.drag(find.byType(ListView).last, const Offset(0, 240));
    await tester.pump();

    expect(navigation.visible, isFalse);
    expect(_position(tester).pixels, greaterThan(0));
  });

  testWidgets('movement toward newest does not hide visible nav', (
    tester,
  ) async {
    final navigation = _visibleNavigation();
    addTearDown(navigation.dispose);
    await _pump(
      tester,
      _ChatController.data(
        _state([_longConversation('direction')], 'direction'),
      ),
      navigation: navigation,
    );
    navigation.hide();
    await _browseOlder(tester);
    navigation.show();
    await tester.pump();

    await tester.drag(find.byType(ListView).last, const Offset(0, -80));
    await tester.pump();

    expect(navigation.visible, isTrue);
  });

  testWidgets('programmatic message insertion does not hide visible nav', (
    tester,
  ) async {
    final conversation = _longConversation('programmatic');
    final chat = _ChatController.data(_state([conversation], 'programmatic'));
    final navigation = _visibleNavigation();
    addTearDown(navigation.dispose);
    await _pump(tester, chat, navigation: navigation);

    chat.publish(
      _state([
        conversation.copyWith(
          messages: [...conversation.messages, _message('inserted', 4)],
        ),
      ], 'programmatic'),
    );
    await tester.pumpAndSettle();

    expect(navigation.visible, isTrue);
    expect(_position(tester).pixels, 0);
  });
}

Future<void> _pump(
  WidgetTester tester,
  _ChatController controller, {
  bool setSize = true,
  ChatNavigationController? navigation,
}) async {
  if (setSize) {
    await tester.binding.setSurfaceSize(const Size(420, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        chatControllerProvider.overrideWith(() => controller),
        modelsControllerProvider.overrideWith(_ModelsController.new),
      ],
      child: MaterialApp(
        home: navigation == null
            ? const ChatScreen()
            : ShellNavigationScope(
                controller: navigation,
                chatNavigationVisible: navigation.visible,
                child: const ChatScreen(),
              ),
      ),
    ),
  );
  if (controller.initial == null) {
    await tester.pump();
  } else {
    await tester.pumpAndSettle();
  }
}

ChatNavigationController _visibleNavigation() => ChatNavigationController()
  ..updatePath('/chat')
  ..updateWidth(true)
  ..show();

Future<void> _browseOlder(WidgetTester tester) async {
  await tester.drag(find.byType(ListView).last, const Offset(0, 500));
  await tester.pumpAndSettle();
  expect(_position(tester).pixels, greaterThan(80));
}

ScrollPosition _position(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView).last).controller!.position;

void _expectAtNewest(WidgetTester tester, String prefix) {
  expect(_position(tester).pixels, 0);
  expect(find.byKey(ValueKey('$prefix-19')), findsOneWidget);
  expect(find.byKey(ValueKey('$prefix-0')), findsNothing);
}

ChatState _state(List<Conversation> conversations, String active) =>
    ChatState(conversations: conversations, activeConversationId: active);

Conversation _longConversation(String id) => _conversation(
  id,
  List.generate(20, (index) => _message('$id-$index', index % 5 + 1)),
);

Conversation _conversation(String id, List<ChatMessage> messages) =>
    Conversation(
      id: id,
      title: 'Conversation $id',
      modelId: 'model',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      messages: messages,
    );

ChatMessage _message(String id, int lines, {String? content}) => ChatMessage(
  id: id,
  role: ChatRole.assistant,
  content:
      content ?? List.generate(lines, (index) => '$id line $index').join('\n'),
  createdAt: DateTime(2026),
  status: ChatMessageStatus.complete,
);

class _ChatController extends ChatController {
  _ChatController._(this.initial, this.completer);

  factory _ChatController.data(ChatState state) =>
      _ChatController._(state, null);
  factory _ChatController.loading() =>
      _ChatController._(null, Completer<ChatState>());

  final ChatState? initial;
  final Completer<ChatState>? completer;

  @override
  Future<ChatState> build() =>
      initial == null ? completer!.future : Future.value(initial);

  void complete(ChatState value) => completer!.complete(value);
  void publish(ChatState value) => state = AsyncData(value);
}

class _ModelsController extends ModelsController {
  @override
  Future<ModelsState> build() async => const ModelsState(
    models: [AiModel(id: 'model')],
    favorites: {},
    hidden: {},
    selectedModelId: 'model',
  );
}
