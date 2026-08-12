import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/core/router/app_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    root = await Directory.systemTemp.createTemp('app-router-');
    Hive.init(root.path);
    await Future.wait([
      Hive.openBox<dynamic>('preferences'),
      Hive.openBox<dynamic>('models'),
      Hive.openBox<dynamic>('conversations'),
    ]);
  });

  tearDown(() async {
    await Hive.close();
    await root.delete(recursive: true);
  });

  testWidgets('shell destinations navigate in exact branch order', (
    tester,
  ) async {
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'assets/translations',
        fallbackLocale: const Locale('en'),
        child: ProviderScope(
          child: Consumer(
            builder: (context, ref, _) => MaterialApp.router(
              routerConfig: ref.watch(appRouterProvider),
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(MaterialApp));
    final router = ProviderScope.containerOf(context).read(appRouterProvider);

    final expected = ['/chat', '/models', '/agents', '/memory', '/settings'];
    for (var index = 0; index < expected.length; index++) {
      await tester.tap(find.byType(NavigationDestination).at(index));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(router.routeInformationProvider.value.uri.path, expected[index]);
    }
  });
}
