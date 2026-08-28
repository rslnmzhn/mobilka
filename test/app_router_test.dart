import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/core/router/app_router.dart';
import 'package:mobilka/features/shell/presentation/app_shell.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('app-router-');
    Hive.init(root.path);
    await Future.wait([
      Hive.openBox<dynamic>('preferences'),
      Hive.openBox<dynamic>('models'),
      Hive.openBox<dynamic>('conversations'),
      Hive.openBox<dynamic>('artifacts'),
    ]);
  });

  tearDown(() async {
    await Hive.close();
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  Future<void> pumpAppAtSize(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);

    await tester.pumpWidget(
      EasyLocalization(
        key: UniqueKey(),
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
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
  }

  testWidgets('shell is responsive, branded, and navigates in branch order', (
    tester,
  ) async {
    await pumpAppAtSize(tester, const Size(320, 720));

    expect(find.byType(NavigationBar), findsOneWidget);
    final mobileNavigation = tester.widget<NavigationBar>(
      find.byType(NavigationBar),
    );
    expect(mobileNavigation.height, 52);
    expect(
      mobileNavigation.labelBehavior,
      NavigationDestinationLabelBehavior.alwaysHide,
    );
    for (final label in ['Chat', 'Models', 'Agents', 'Memory', 'Settings']) {
      expect(find.text(label), findsWidgets);
    }
    expect(find.text('MOBILKA'), findsNothing);
    expect(find.text('Workbench'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(
      const Size(expandedShellBreakpoint + 180, 800),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('MOBILKA'), findsOneWidget);
    expect(find.text('Workbench'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('mobilka-brand-mark')),
        matching: find.text('M'),
      ),
      findsOneWidget,
    );
    expect(find.text('H'), findsNothing);
    for (final label in ['Chat', 'Models', 'Agents', 'Memory', 'Settings']) {
      expect(find.text(label), findsWidgets);
    }
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(
      const Size(compactShellBreakpoint + 100, 800),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('mobilka-brand-mark')),
        matching: find.text('M'),
      ),
      findsOneWidget,
    );
    expect(find.text('H'), findsNothing);

    final context = tester.element(find.byType(MaterialApp));
    final router = ProviderScope.containerOf(context).read(appRouterProvider);

    final expected = ['/chat', '/models', '/agents', '/memory', '/settings'];
    final labels = ['Chat', 'Models', 'Agents', 'Memory', 'Settings'];
    for (var index = 0; index < expected.length; index++) {
      await tester.tap(find.text(labels[index]).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(router.routeInformationProvider.value.uri.path, expected[index]);
    }
    await disposeApp(tester);
  });

  test(
    'session artifact route is root-level and distinct from global route',
    () {
      final session = appRoutes.whereType<GoRoute>().single;
      final shell = appRoutes.whereType<StatefulShellRoute>().single;
      final chat = shell.branches.first.routes.single as GoRoute;
      final global = chat.routes.single as GoRoute;

      expect(session.path, '/chat/:conversationId/artifacts');
      expect(session.parentNavigatorKey, same(rootNavigatorKey));
      expect(session.pageBuilder, isNotNull);
      expect(global.path, 'artifacts');
      expect(global.parentNavigatorKey, isNull);
      expect(session.path, isNot('/chat/artifacts'));
    },
  );
}
