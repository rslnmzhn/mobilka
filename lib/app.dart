import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';

class MobilkaApp extends ConsumerWidget {
  const MobilkaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeControllerProvider);
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'mobilka',
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
