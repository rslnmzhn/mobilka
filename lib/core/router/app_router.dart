import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/chat/presentation/chat_screen.dart';
import '../../features/memory/presentation/memory_screen.dart';
import '../../features/models/presentation/models_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/shell/presentation/app_shell.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/chat',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/chat', builder: (_, _) => const ChatScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/models', builder: (_, _) => const ModelsScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/memory', builder: (_, _) => const MemoryScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (_, _) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
