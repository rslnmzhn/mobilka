import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'features/chat/application/background_task_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  await Hive.initFlutter();
  if (!kIsWeb && Platform.isAndroid) {
    AndroidForegroundTaskBridge.initialize();
  }
  await Future.wait([
    Hive.openBox<dynamic>('preferences'),
    Hive.openBox<dynamic>('models'),
    Hive.openBox<dynamic>('conversations'),
    Hive.openBox<dynamic>('memory_recovery'),
    Hive.openBox<dynamic>('memory_proposals'),
    Hive.openBox<dynamic>('artifacts'),
    Hive.openBox<dynamic>('workspace_recovery'),
  ]);

  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('en'), Locale('ru')],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      child: const ProviderScope(child: MobilkaApp()),
    ),
  );
}
