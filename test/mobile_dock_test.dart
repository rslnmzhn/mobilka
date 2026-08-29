import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mobilka/features/shell/presentation/app_shell.dart';
import 'package:mobilka/features/shell/presentation/mobile_dock.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _labels = ['Chat', 'Models', 'Agents', 'Memory', 'Settings'];
const _destinations = [
  (Icons.chat_outlined, Icons.chat, 'Chat'),
  (Icons.hub_outlined, Icons.hub, 'Models'),
  (Icons.smart_toy_outlined, Icons.smart_toy, 'Agents'),
  (Icons.folder_outlined, Icons.folder, 'Memory'),
  (Icons.tune_outlined, Icons.tune, 'Settings'),
];

class _DockAssetLoader extends AssetLoader {
  const _DockAssetLoader();

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      locale.languageCode == 'ru'
      ? {
          'nav': {
            'chat': 'Чат',
            'models': 'Модели',
            'agents': 'Агенты',
            'memory': 'Память',
            'settings': 'Настройки',
            'show': 'Показать навигацию',
            'showHint': 'Проведите вверх, чтобы открыть навигацию',
            'hide': 'Скрыть навигацию',
            'hideHint': 'Проведите вниз, чтобы скрыть навигацию',
          },
        }
      : {
          'nav': {
            'chat': 'Chat',
            'models': 'Models',
            'agents': 'Agents',
            'memory': 'Memory',
            'settings': 'Settings',
            'show': 'Show navigation',
            'showHint': 'Swipe up to reveal navigation',
            'hide': 'Hide navigation',
            'hideHint': 'Swipe down to hide navigation',
          },
        };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpDock(
    WidgetTester tester, {
    required bool expanded,
    bool canCollapse = true,
    required VoidCallback onShow,
    required VoidCallback onHide,
    ValueChanged<int>? onSelect,
    Locale locale = const Locale('en'),
    EdgeInsets padding = EdgeInsets.zero,
    EdgeInsets systemGestureInsets = EdgeInsets.zero,
    EdgeInsets viewInsets = EdgeInsets.zero,
    bool disableAnimations = false,
  }) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(320, 640));
    await tester.pumpWidget(
      EasyLocalization(
        key: UniqueKey(),
        supportedLocales: const [Locale('en'), Locale('ru')],
        path: 'assets/translations',
        assetLoader: const _DockAssetLoader(),
        fallbackLocale: const Locale('en'),
        startLocale: locale,
        child: Builder(
          builder: (context) => MaterialApp(
            locale: locale,
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 640),
                padding: padding,
                systemGestureInsets: systemGestureInsets,
                viewInsets: viewInsets,
                disableAnimations: disableAnimations,
              ),
              child: Scaffold(
                body: const ColoredBox(
                  key: Key('mock-body'),
                  color: Colors.blue,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: SizedBox(
                      key: Key('mock-composer'),
                      height: 64,
                      width: double.infinity,
                    ),
                  ),
                ),
                bottomNavigationBar: MobileDock(
                  expanded: expanded,
                  canCollapse: canCollapse,
                  destinations: _destinations,
                  selectedIndex: 0,
                  onSelect: onSelect ?? (_) {},
                  onShow: onShow,
                  onHide: onHide,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
  }

  testWidgets('dock collapse policy uses the exact URI path only', (
    tester,
  ) async {
    expect(isCollapsedMobileDockPath('/chat'), isTrue);
    expect(isCollapsedMobileDockPath(Uri.parse('/chat?q=1').path), isTrue);
    expect(isCollapsedMobileDockPath('/chat/'), isFalse);
    expect(isCollapsedMobileDockPath('/chat/artifacts'), isFalse);
    expect(isCollapsedMobileDockPath('/models'), isFalse);
  });

  testWidgets('collapsed dock has safe geometry and tap reveal', (
    tester,
  ) async {
    var shows = 0;
    await pumpDock(
      tester,
      expanded: false,
      padding: const EdgeInsets.only(bottom: 24),
      onShow: () => shows++,
      onHide: () {},
    );

    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(mobileDockIndicatorKey), findsOneWidget);
    expect(tester.getSize(find.byKey(mobileDockIndicatorKey)).height, 48);
    expect(tester.getBottomLeft(find.byKey(mobileDockIndicatorKey)).dy, 616);
    final bodyBottom = tester
        .getBottomLeft(find.byKey(const Key('mock-body')))
        .dy;
    final dockTop = tester.getTopLeft(find.byType(MobileDock)).dy;
    expect(bodyBottom, dockTop);
    expect(
      tester.getBottomLeft(find.byKey(const Key('mock-composer'))).dy,
      lessThanOrEqualTo(dockTop),
    );

    await tester.tap(find.byKey(mobileDockIndicatorKey));
    expect(shows, 1);
  });

  testWidgets('collapsed dock accepts only committed upward drag', (
    tester,
  ) async {
    var shows = 0;
    await pumpDock(
      tester,
      expanded: false,
      onShow: () => shows++,
      onHide: () {},
    );
    final control = find.byKey(mobileDockIndicatorKey);

    await tester.drag(control, const Offset(0, -30));
    await tester.drag(control, const Offset(80, 0));
    await tester.drag(control, const Offset(0, 60));
    expect(shows, 0);
    await tester.drag(control, const Offset(0, -60));
    expect(shows, 1);
  });

  testWidgets('expanded dock exposes destinations and hide interactions', (
    tester,
  ) async {
    var hides = 0;
    var selected = -1;
    await pumpDock(
      tester,
      expanded: true,
      onShow: () {},
      onHide: () => hides++,
      onSelect: (value) => selected = value,
    );

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    final semantics = tester.ensureSemantics();
    final barNode = tester.getSemantics(find.byType(NavigationBar));
    for (final label in _labels) {
      expect(barNode.toStringDeep(), contains(label));
    }
    semantics.dispose();
    await tester.tap(find.byType(NavigationDestination).at(3));
    expect(selected, 3);
    await tester.tap(find.byKey(mobileDockHideKey));
    expect(hides, 1);
    await tester.drag(find.byKey(mobileDockHideKey), const Offset(0, 60));
    expect(hides, 2);
  });

  testWidgets('non-collapsible expanded dock omits dead hide affordance', (
    tester,
  ) async {
    var selected = -1;
    await pumpDock(
      tester,
      expanded: true,
      canCollapse: false,
      onShow: () {},
      onHide: () => fail('non-collapsible dock must not hide'),
      onSelect: (value) => selected = value,
    );

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byKey(mobileDockHideKey), findsNothing);
    expect(find.bySemanticsLabel('Hide navigation'), findsNothing);
    expect(tester.getSize(find.byType(MobileDock)).height, 52);
    await tester.tap(find.byType(NavigationDestination).at(2));
    expect(selected, 2);
  });

  testWidgets('control supports keyboard Enter and Space', (tester) async {
    var shows = 0;
    await pumpDock(
      tester,
      expanded: false,
      onShow: () => shows++,
      onHide: () {},
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(shows, 2);
  });

  testWidgets('localized semantic buttons expose tap actions once', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var shows = 0;
    var hides = 0;
    await pumpDock(
      tester,
      expanded: false,
      onShow: () => shows++,
      onHide: () {},
    );
    var node = tester.getSemantics(find.byKey(mobileDockIndicatorKey));
    expect(node.label, 'Show navigation');
    expect(node.hint, 'Swipe up to reveal navigation');
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(find.bySemanticsLabel('Show navigation'), findsOneWidget);
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pump();
    expect(shows, 1);

    await pumpDock(
      tester,
      expanded: true,
      locale: const Locale('ru'),
      onShow: () {},
      onHide: () => hides++,
    );
    node = tester.getSemantics(find.byKey(mobileDockHideKey));
    expect(node.label, 'Скрыть навигацию');
    expect(node.hint, 'Проведите вниз, чтобы скрыть навигацию');
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pump();
    expect(hides, 1);
    handle.dispose();
  });

  testWidgets('insets remain reachable without overflow or body overlap', (
    tester,
  ) async {
    await pumpDock(
      tester,
      expanded: false,
      padding: const EdgeInsets.only(bottom: 20),
      systemGestureInsets: const EdgeInsets.only(bottom: 32),
      viewInsets: const EdgeInsets.only(bottom: 280),
      disableAnimations: true,
      onShow: () {},
      onHide: () {},
    );
    expect(tester.takeException(), isNull);
    final control = find.byKey(mobileDockIndicatorKey);
    expect(tester.getBottomLeft(control).dy, 328);
    expect(tester.getBottomLeft(control).dy, lessThanOrEqualTo(640 - 280 - 32));
    expect(
      tester.getBottomLeft(find.byKey(const Key('mock-body'))).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.byType(MobileDock)).dy),
    );

    await pumpDock(
      tester,
      expanded: true,
      padding: const EdgeInsets.only(bottom: 20),
      systemGestureInsets: const EdgeInsets.only(bottom: 32),
      viewInsets: const EdgeInsets.only(bottom: 280),
      disableAnimations: true,
      onShow: () {},
      onHide: () {},
    );
    expect(
      tester.getBottomLeft(find.byType(NavigationBar)).dy,
      lessThanOrEqualTo(640 - 280 - 32),
    );
    expect(tester.takeException(), isNull);
  });

  group('fresh route-aware shell', () {
    late GoRouter router;

    Future<void> pumpShell(
      WidgetTester tester, {
      String initial = '/chat',
      double width = 320,
    }) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(Size(width, 720));
      router = GoRouter(
        initialLocation: initial,
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (_, state, shell) =>
                AppShell(shell: shell, currentPath: state.uri.path),
            branches: [
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/chat',
                    builder: (_, _) => const Text('chat-body'),
                    routes: [
                      GoRoute(
                        path: 'artifacts',
                        builder: (_, _) => const Text('artifacts-body'),
                      ),
                    ],
                  ),
                ],
              ),
              for (final route in const [
                ('/models', 'models-body'),
                ('/agents', 'agents-body'),
                ('/memory', 'memory-body'),
                ('/settings', 'settings-body'),
              ])
                StatefulShellBranch(
                  routes: [
                    GoRoute(path: route.$1, builder: (_, _) => Text(route.$2)),
                  ],
                ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        EasyLocalization(
          key: UniqueKey(),
          supportedLocales: const [Locale('en')],
          path: 'assets/translations',
          assetLoader: const _DockAssetLoader(),
          fallbackLocale: const Locale('en'),
          child: Builder(
            builder: (context) => MaterialApp.router(
              routerConfig: router,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
    }

    tearDown(() => router.dispose());

    testWidgets(
      'routes expand appropriately and branch selection resets chat',
      (tester) async {
        await pumpShell(tester);
        expect(find.byKey(mobileDockIndicatorKey), findsOneWidget);
        await tester.tap(find.byKey(mobileDockIndicatorKey));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(NavigationDestination).at(1));
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/models');
        expect(find.byType(NavigationBar), findsOneWidget);
        await tester.tap(find.byType(NavigationDestination).first);
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/chat');
        expect(find.byKey(mobileDockIndicatorKey), findsOneWidget);

        router.go('/chat/artifacts');
        await tester.pumpAndSettle();
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(find.byKey(mobileDockHideKey), findsNothing);
        expect(find.bySemanticsLabel('Hide navigation'), findsNothing);
        await tester.tap(find.byType(NavigationDestination).at(1));
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/models');
        expect(find.byKey(mobileDockHideKey), findsNothing);
      },
    );

    testWidgets('breakpoints and desktop to mobile preserve policy', (
      tester,
    ) async {
      await pumpShell(tester, width: 759);
      expect(find.byKey(mobileDockIndicatorKey), findsOneWidget);
      await tester.binding.setSurfaceSize(const Size(760, 720));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byKey(mobileDockIndicatorKey), findsNothing);
      await tester.binding.setSurfaceSize(const Size(1099, 720));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      await tester.binding.setSurfaceSize(const Size(1100, 720));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('MOBILKA'), findsOneWidget);
      expect(find.byKey(mobileDockIndicatorKey), findsNothing);
      await tester.binding.setSurfaceSize(const Size(320, 720));
      await tester.pumpAndSettle();
      expect(find.byKey(mobileDockIndicatorKey), findsOneWidget);
    });
  });
}
