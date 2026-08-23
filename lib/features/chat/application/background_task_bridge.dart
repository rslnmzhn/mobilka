import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'background_task_bridge.g.dart';

/// Platform bridge for user-visible long-running task execution.
///
/// Android backs this with a Foreground Service + notification so streaming
/// survives backgrounding; every other platform is a no-op. The streaming
/// coordinator calls [start] when a request begins and [stop] when it ends,
/// regardless of outcome.
abstract interface class BackgroundTaskBridge {
  Future<void> start({required String title});

  Future<void> stop();
}

class NoopBackgroundTaskBridge implements BackgroundTaskBridge {
  const NoopBackgroundTaskBridge();

  @override
  Future<void> start({required String title}) async {}

  @override
  Future<void> stop() async {}
}

class AndroidForegroundTaskBridge implements BackgroundTaskBridge {
  const AndroidForegroundTaskBridge();

  @override
  Future<void> start({required String title}) async {
    await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.dataSync],
      notificationTitle: title,
      notificationText: 'mobilka is working in the background',
    );
  }

  @override
  Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}

@Riverpod(keepAlive: true)
BackgroundTaskBridge backgroundTaskBridge(Ref ref) {
  if (kIsWeb) return const NoopBackgroundTaskBridge();
  return Platform.isAndroid
      ? const AndroidForegroundTaskBridge()
      : const NoopBackgroundTaskBridge();
}
