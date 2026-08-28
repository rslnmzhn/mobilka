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

  Future<BackgroundTaskStopResult> stop({required String ownerId});
}

enum BackgroundTaskStartResult { started, alreadyRunning, unavailable }

enum BackgroundTaskStopResult { released, notRunning, retainedForRetry }

class NoopBackgroundTaskBridge implements BackgroundTaskBridge {
  const NoopBackgroundTaskBridge();

  @override
  Future<BackgroundTaskStartResult> start({
    required String ownerId,
    required String title,
  }) async => BackgroundTaskStartResult.started;

  @override
  Future<BackgroundTaskStopResult> stop({required String ownerId}) async =>
      BackgroundTaskStopResult.notRunning;
}

class AndroidForegroundTaskBridge implements BackgroundTaskBridge {
  static const notificationTitle = 'mobilka';
  static const notificationText = 'Response generation in progress';

  AndroidForegroundTaskBridge({
    Future<ServiceRequestResult> Function(String title)? startService,
    Future<bool> Function()? isRunning,
    Future<ServiceRequestResult> Function()? stopService,
    Future<void> Function(Duration delay)? cleanupDelay,
    void Function(String status)? onCleanupStatus,
    List<Duration> cleanupRetryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 3),
      Duration(seconds: 10),
    ],
  }) : _startService = startService ?? _pluginStart,
       _isRunning = isRunning ?? (() => FlutterForegroundTask.isRunningService),
       _stopService = stopService ?? FlutterForegroundTask.stopService,
       _cleanupDelay = cleanupDelay ?? Future<void>.delayed,
       _onCleanupStatus = onCleanupStatus,
       _cleanupRetryDelays = List.unmodifiable(cleanupRetryDelays);

  final Future<ServiceRequestResult> Function(String title) _startService;
  final Future<bool> Function() _isRunning;
  final Future<ServiceRequestResult> Function() _stopService;
  final Future<void> Function(Duration delay) _cleanupDelay;
  final void Function(String status)? _onCleanupStatus;
  final List<Duration> _cleanupRetryDelays;
  final Set<String> _owners = {};
  bool _cleanupPending = false;
  String? _cleanupOwner;
  int _cleanupGeneration = 0;
  bool _cleanupScheduled = false;
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
      foregroundTaskOptions: foregroundTaskOptions(),
    );
  }

  @visibleForTesting
  static ForegroundTaskOptions foregroundTaskOptions() => ForegroundTaskOptions(
    eventAction: ForegroundTaskEventAction.nothing(),
    autoRunOnBoot: false,
    autoRunOnMyPackageReplaced: false,
    allowWakeLock: true,
    allowWifiLock: false,
    allowAutoRestart: false,
    // The request-scoped lease is the sole normal service stop owner.
    stopWithTask: false,
  );

  static Future<ServiceRequestResult> _pluginStart(String _) =>
      FlutterForegroundTask.startService(
        serviceTypes: const [ForegroundServiceTypes.dataSync],
        notificationTitle: notificationTitle,
        notificationText: notificationText,
      );

  @override
  Future<BackgroundTaskStartResult> start({
    required String ownerId,
    required String title,
  }) => _serialized(() async {
    await _retryPendingCleanup();
    if (_owners.contains(ownerId)) {
      return BackgroundTaskStartResult.alreadyRunning;
    }
    if (_owners.isNotEmpty || await _isRunning()) {
      _owners.add(ownerId);
      return BackgroundTaskStartResult.alreadyRunning;
    }
    final result = await _startService(notificationTitle);
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
  Future<BackgroundTaskStopResult> stop({required String ownerId}) =>
      _serialized(() async {
        if (!_owners.contains(ownerId)) {
          return BackgroundTaskStopResult.notRunning;
        }
        if (_owners.length > 1) {
          _owners.remove(ownerId);
          if (_cleanupPending) _scheduleCleanup();
          return BackgroundTaskStopResult.released;
        }
        final outcome = await _tryStop(attempts: 2);
        if (outcome != BackgroundTaskStopResult.retainedForRetry) {
          _owners.remove(ownerId);
          _clearCleanupPending();
        } else {
          _cleanupPending = true;
          _cleanupOwner = ownerId;
          _onCleanupStatus?.call('cleanup_pending');
          _scheduleCleanup();
        }
        return outcome;
      });

  Future<void> _retryPendingCleanup() async {
    if (!_cleanupPending || _owners.length != 1) return;
    final outcome = await _tryStop(attempts: 1);
    if (outcome != BackgroundTaskStopResult.retainedForRetry) {
      _owners.clear();
      _clearCleanupPending();
    }
  }

  void _scheduleCleanup() {
    if (_cleanupScheduled || !_cleanupPending || _cleanupOwner == null) return;
    _cleanupScheduled = true;
    final generation = ++_cleanupGeneration;
    final owner = _cleanupOwner!;
    Future<void>(() async {
      for (final delay in _cleanupRetryDelays) {
        await _cleanupDelay(delay);
        if (generation != _cleanupGeneration || !_cleanupPending) return;
        final outcome = await _serialized(() async {
          if (generation != _cleanupGeneration ||
              !_cleanupPending ||
              _cleanupOwner != owner ||
              _owners.length != 1 ||
              !_owners.contains(owner)) {
            return BackgroundTaskStopResult.retainedForRetry;
          }
          return _tryStop(attempts: 1);
        });
        if (generation != _cleanupGeneration || !_cleanupPending) return;
        if (outcome != BackgroundTaskStopResult.retainedForRetry) {
          await _serialized(() async {
            if (generation == _cleanupGeneration && _cleanupOwner == owner) {
              _owners.remove(owner);
              _clearCleanupPending();
            }
          });
          return;
        }
      }
      if (generation == _cleanupGeneration && _cleanupPending) {
        _cleanupScheduled = false;
        _onCleanupStatus?.call('cleanup_exhausted');
      }
    });
  }

  void _clearCleanupPending() {
    _cleanupPending = false;
    _cleanupOwner = null;
    _cleanupScheduled = false;
    _cleanupGeneration++;
  }

  Future<BackgroundTaskStopResult> _tryStop({required int attempts}) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        if (!await _isRunning()) return BackgroundTaskStopResult.notRunning;
        final result = await _stopService();
        if (result is ServiceRequestSuccess) {
          return BackgroundTaskStopResult.released;
        }
      } on Object {
        // A bounded retry or the next serialized operation owns recovery.
      }
    }
    return BackgroundTaskStopResult.retainedForRetry;
  }
}

@Riverpod(keepAlive: true)
BackgroundTaskBridge backgroundTaskBridge(Ref ref) {
  if (kIsWeb) return const NoopBackgroundTaskBridge();
  return Platform.isAndroid
      ? AndroidForegroundTaskBridge()
      : const NoopBackgroundTaskBridge();
}
