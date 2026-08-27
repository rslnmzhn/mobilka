import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/logging/app_logger.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'features/chat/application/chat_controller.dart';
import 'features/memory/data/memory_repository.dart';
import 'features/updater/application/update_controller.dart';

class MobilkaApp extends ConsumerStatefulWidget {
  const MobilkaApp({super.key});

  @override
  ConsumerState<MobilkaApp> createState() => _MobilkaAppState();
}

class _MobilkaAppState extends ConsumerState<MobilkaApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future<void>.microtask(() async {
      // Memory 2.0: rename legacy files before anything reads them.
      try {
        final conflicts = await ref
            .read(memoryRepositoryProvider)
            .migrateLegacyFiles();
        for (final conflict in conflicts) {
          ref
              .read(appLoggerProvider)
              .log(
                event: 'memory.legacy_migration',
                status: 'conflict',
                error: '${conflict.oldName} -> ${conflict.newName}',
              );
        }
      } on Object catch (error) {
        // Keep startup available without clearing the saved location. The
        // actionable access/migration failure remains visible in diagnostics.
        ref
            .read(appLoggerProvider)
            .log(
              event: 'memory.legacy_migration',
              status: 'failed',
              error: error,
            );
      }
      await ref.read(updateControllerProvider.notifier).check();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Roadmap item 47: an in-flight stream already persists every delta, but
    // the final batch can still be lost on process death — flush the newest
    // snapshot whenever the app leaves the foreground.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      final controller = ref.read(chatControllerProvider.notifier);
      Future<void>.microtask(controller.flushActiveConversation);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeControllerProvider);
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'mobilka Workbench',
      routerConfig: ref.watch(appRouterProvider),
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      theme: AppTheme.build(theme.preset, Brightness.light),
      darkTheme: AppTheme.build(theme.preset, Brightness.dark),
      themeMode: theme.mode,
    );
  }
}
