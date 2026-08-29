import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/chat/presentation/chat_screen.dart';
import '../../features/artifacts/presentation/artifacts_screen.dart';
import '../../features/artifacts/presentation/session_artifacts_screen.dart';
import '../../features/agents/presentation/agents_screen.dart';
import '../../features/memory/presentation/memory_screen.dart';
import '../../features/models/presentation/models_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/shell/presentation/app_shell.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

final appRouterProvider = Provider<GoRouter>(
  (ref) => GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/chat',
    routes: appRoutes,
  ),
);

final List<RouteBase> appRoutes = [
  GoRoute(
    parentNavigatorKey: rootNavigatorKey,
    path: '/chat/:conversationId/artifacts',
    pageBuilder: (context, state) => CustomTransitionPage<void>(
      key: state.pageKey,
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      child: SessionArtifactsScreen(
        conversationId: state.pathParameters['conversationId']!,
      ),
      transitionsBuilder: (context, animation, secondary, child) =>
          SlideTransition(
            position: animation.drive(
              Tween(
                begin: const Offset(1, 0),
                end: Offset.zero,
              ).chain(CurveTween(curve: Curves.easeOutCubic)),
            ),
            child: child,
          ),
    ),
  ),
  StatefulShellRoute.indexedStack(
    builder: (context, state, shell) =>
        AppShell(shell: shell, currentPath: state.uri.path),
    branches: [
      StatefulShellBranch(
        routes: [
          GoRoute(
            path: '/chat',
            builder: (_, _) => const ChatScreen(),
            routes: [
              GoRoute(
                path: 'artifacts',
                builder: (_, _) => const ArtifactsScreen(),
              ),
            ],
          ),
        ],
      ),
      StatefulShellBranch(
        routes: [
          GoRoute(path: '/models', builder: (_, _) => const ModelsScreen()),
        ],
      ),
      StatefulShellBranch(
        routes: [
          GoRoute(path: '/agents', builder: (_, _) => const AgentsScreen()),
        ],
      ),
      StatefulShellBranch(
        routes: [
          GoRoute(path: '/memory', builder: (_, _) => const MemoryScreen()),
        ],
      ),
      StatefulShellBranch(
        routes: [
          GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
        ],
      ),
    ],
  ),
];
