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
  Future<BackgroundTaskStartResult> start({
    required String ownerId,
    required String title,
  });

  Future<void> stop({required String ownerId});
}

enum BackgroundTaskStartResult { started, alreadyRunning, unavailable }

class NoopBackgroundTaskBridge implements BackgroundTaskBridge {
  const NoopBackgroundTaskBridge();

  @override
  Future<BackgroundTaskStartResult> start({
    required String ownerId,
    required String title,
  }) async => BackgroundTaskStartResult.started;

  @override
  Future<void> stop({required String ownerId}) async {}
}

class AndroidForegroundTaskBridge implements BackgroundTaskBridge {
  AndroidForegroundTaskBridge({
    Future<ServiceRequestResult> Function(String title)? startService,
    Future<bool> Function()? isRunning,
    Future<ServiceRequestResult> Function()? stopService,
  }) : _startService = startService ?? _pluginStart,
       _isRunning = isRunning ?? (() => FlutterForegroundTask.isRunningService),
       _stopService = stopService ?? FlutterForegroundTask.stopService;

  final Future<ServiceRequestResult> Function(String title) _startService;
  final Future<bool> Function() _isRunning;
  final Future<ServiceRequestResult> Function() _stopService;
  final Set<String> _owners = {};
  Future<void> _serial = Future.value();

  static void initialize() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'mobilka_streaming',
        channelName: 'mobilka background responses',
        channelDescription: 'Shows while mobilka is receiving a response.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
        allowAutoRestart: false,
        stopWithTask: true,
      ),
    );
  }

  static Future<ServiceRequestResult> _pluginStart(String title) =>
      FlutterForegroundTask.startService(
        serviceTypes: const [ForegroundServiceTypes.dataSync],
        notificationTitle: title,
        notificationText: 'mobilka is receiving a response',
      );

  @override
  Future<BackgroundTaskStartResult> start({
    required String ownerId,
    required String title,
  }) => _serialized(() async {
    if (_owners.contains(ownerId)) {
      return BackgroundTaskStartResult.alreadyRunning;
    }
    if (_owners.isNotEmpty || await _isRunning()) {
      _owners.add(ownerId);
      return BackgroundTaskStartResult.alreadyRunning;
    }
    final result = await _startService(title);
    if (result is ServiceRequestFailure) {
      return BackgroundTaskStartResult.unavailable;
    }
    _owners.add(ownerId);
    return BackgroundTaskStartResult.started;
  });

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _serial.then((_) => operation());
    _serial = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<void> stop({required String ownerId}) => _serialized(() async {
    if (!_owners.remove(ownerId) || _owners.isNotEmpty) return;
    if (await _isRunning()) {
      await _stopService();
    }
  });
}

@Riverpod(keepAlive: true)
BackgroundTaskBridge backgroundTaskBridge(Ref ref) {
  if (kIsWeb) return const NoopBackgroundTaskBridge();
  return Platform.isAndroid
      ? AndroidForegroundTaskBridge()
      : const NoopBackgroundTaskBridge();
}
