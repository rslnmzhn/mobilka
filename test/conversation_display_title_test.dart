import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/chat/presentation/conversation_display_title.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('automatic titles localize on locale switch without mutation', (
    tester,
  ) async {
    final pending = _conversation(ConversationTitleState.pendingAutomatic);
    final fallback = _conversation(ConversationTitleState.fallback);
    final generated = _conversation(
      ConversationTitleState.generated,
      title: 'Generated title',
    );
    late BuildContext localizedContext;
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('en'), Locale('ru')],
        path: 'assets/translations',
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('en'),
        child: Builder(
          builder: (context) {
            localizedContext = context;
            return MaterialApp(
              locale: context.locale,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              home: Builder(
                builder: (context) => Text(
                  '${conversationDisplayTitle(pending)}|'
                  '${conversationDisplayTitle(fallback)}|'
                  '${conversationDisplayTitle(generated)}',
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('New chat|New chat|Generated title'), findsOneWidget);
    await localizedContext.setLocale(const Locale('ru'));
    await tester.pumpAndSettle();
    expect(find.text('Новый чат|Новый чат|Generated title'), findsOneWidget);
    expect(pending.title, 'New conversation');
  });
}

Conversation _conversation(
  ConversationTitleState state, {
  String title = 'New conversation',
}) => Conversation(
  id: state.name,
  title: title,
  modelId: 'model',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  messages: const [],
  titleState: state,
);
