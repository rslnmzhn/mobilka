import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/presentation/chat_message_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  ChatMessage message({
    required String id,
    required ChatRole role,
    required String content,
    String reasoning = '',
    ChatMessageStatus status = ChatMessageStatus.complete,
    List<ChatToolCall> toolCalls = const [],
  }) => ChatMessage(
    id: id,
    role: role,
    content: content,
    createdAt: DateTime(2026),
    reasoningContent: reasoning,
    status: status,
    toolCalls: toolCalls,
  );

  Future<void> pumpMessage(
    WidgetTester tester,
    ChatMessage value, {
    Locale? locale,
  }) {
    final card = Scaffold(body: MessageCard(message: value));
    if (locale == null) {
      return tester.pumpWidget(MaterialApp(home: card));
    }
    return tester.pumpWidget(
      EasyLocalization(
        key: UniqueKey(),
        supportedLocales: const [Locale('en'), Locale('ru')],
        path: 'assets/translations',
        fallbackLocale: const Locale('en'),
        startLocale: locale,
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: card,
          ),
        ),
      ),
    );
  }

  Future<void> tapBubblePadding(WidgetTester tester, String id) async {
    final rect = tester.getRect(find.byKey(Key('message-bubble-$id')));
    await tester.tapAt(Offset(rect.right - 4, rect.bottom - 4));
  }

  testWidgets('user and assistant copy their exact independent content', (
    tester,
  ) async {
    final writes = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          writes.add((call.arguments as Map)['text'] as String?);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    const userText = '  hello\n```dart\nprint("user");\n```\n';
    const assistantText = '# Answer\n\nline two\n';

    await pumpMessage(
      tester,
      message(id: 'user-1', role: ChatRole.user, content: userText),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('copy-message-user-1')), findsNothing);
    await tapBubblePadding(tester, 'user-1');
    await tester.pump();
    await tester.tap(find.byKey(const Key('copy-message-user-1')));
    await tester.pump();

    await pumpMessage(
      tester,
      message(
        id: 'assistant-1',
        role: ChatRole.assistant,
        content: assistantText,
        reasoning: 'private reasoning',
        status: ChatMessageStatus.interrupted,
        toolCalls: const [
          ChatToolCall(id: 'call-1', name: 'tool_name', arguments: '{}'),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tapBubblePadding(tester, 'assistant-1');
    await tester.pump();
    await tester.tap(find.byKey(const Key('copy-message-assistant-1')));
    await tester.pump();

    expect(writes, [userText, assistantText]);
    expect(writes.last, isNot(contains('private reasoning')));
    expect(writes.last, isNot(contains('interrupted')));
    expect(writes.last, isNot(contains('tool_name')));
  });

  testWidgets('copy action is absent for empty, system, and tool messages', (
    tester,
  ) async {
    for (final value in [
      message(id: 'empty', role: ChatRole.user, content: ''),
      message(id: 'system', role: ChatRole.system, content: 'system'),
      message(id: 'tool', role: ChatRole.tool, content: 'tool'),
    ]) {
      await pumpMessage(tester, value);
      await tester.pumpAndSettle();
      expect(find.byKey(Key('copy-message-${value.id}')), findsNothing);
    }
  });

  testWidgets('localized tooltip and semantics are exposed without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpMessage(
      tester,
      message(id: 'ru', role: ChatRole.assistant, content: 'Ответ'),
      locale: const Locale('ru'),
    );
    await tester.pumpAndSettle();
    await tapBubblePadding(tester, 'ru');
    await tester.pump();
    final semantics = tester.ensureSemantics();

    final button = find.byKey(const Key('copy-message-ru'));
    expect(find.byTooltip('Копировать сообщение'), findsOneWidget);
    expect(
      tester.getSemantics(button),
      matchesSemantics(
        label: 'Копировать сообщение',
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('shows localized success and failure feedback', (tester) async {
    var fail = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData' && fail) {
          throw PlatformException(code: 'clipboard_failed');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpMessage(
      tester,
      message(id: 'feedback', role: ChatRole.user, content: 'text'),
      locale: const Locale('en'),
    );
    await tester.pumpAndSettle();
    await tapBubblePadding(tester, 'feedback');
    await tester.pump();

    await tester.tap(find.byKey(const Key('copy-message-feedback')));
    await tester.pump();
    expect(find.text('Message copied'), findsOneWidget);

    await tester.pump();
    fail = true;
    await tester.tap(find.byKey(const Key('copy-message-feedback')));
    await tester.pump();
    expect(find.text('Could not copy message'), findsOneWidget);
  });
}
