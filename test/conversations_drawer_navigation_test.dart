import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mobilka/features/chat/application/chat_controller.dart';
import 'package:mobilka/features/chat/presentation/conversations_drawer.dart';

void main() {
  testWidgets('drawer closes and navigates to nested artifact route', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/chat',
      routes: [
        GoRoute(
          path: '/chat',
          builder: (_, _) => Scaffold(
            drawer: const ConversationsDrawer(
              chat: AsyncData(ChatState(conversations: [])),
            ),
            body: const Text('Chat'),
          ),
          routes: [
            GoRoute(
              path: 'artifacts',
              builder: (_, _) => const Scaffold(body: Text('Catalog route')),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold));
    scaffold.openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('global-artifacts')));
    await tester.pumpAndSettle();

    expect(router.routeInformationProvider.value.uri.path, '/chat/artifacts');
    expect(find.text('Catalog route'), findsOneWidget);
  });
}
