import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'features/updater/application/update_controller.dart';

class MobilkaApp extends ConsumerStatefulWidget {
  const MobilkaApp({super.key});

  @override
  ConsumerState<MobilkaApp> createState() => _MobilkaAppState();
}

class _MobilkaAppState extends ConsumerState<MobilkaApp> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(
      () => ref.read(updateControllerProvider.notifier).check(),
    );
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
