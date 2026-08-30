import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/presentation/chat_message_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final locale in const [Locale('en'), Locale('ru')]) {
    for (final width in const [320.0]) {
      testWidgets('empty chat ${locale.languageCode} ${width.toInt()} scales', (
        tester,
      ) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.binding.setSurfaceSize(Size(width, 360));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          EasyLocalization(
            supportedLocales: const [Locale('en'), Locale('ru')],
            path: 'assets/translations',
            fallbackLocale: const Locale('en'),
            startLocale: locale,
            child: Builder(
              builder: (context) => MaterialApp(
                locale: locale,
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                home: MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(1.5)),
                  child: Scaffold(body: EmptyChat(onCreate: () {})),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final title = find
            .descendant(of: find.byType(EmptyChat), matching: find.byType(Text))
            .first;
        final text = tester.widget<Text>(title);
        expect(text.textAlign, TextAlign.center);
        final rect = tester.getRect(title);
        expect(rect.left, greaterThanOrEqualTo(20));
        expect(rect.right, lessThanOrEqualTo(width - 20));
        expect(find.byIcon(Icons.add), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
