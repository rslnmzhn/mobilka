import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:mobilka/features/chat/application/background_task_bridge.dart';
import 'package:mobilka/features/chat/application/chat_background_lease.dart';
import 'package:mobilka/features/chat/application/chat_stream_request.dart';
import 'package:mobilka/core/logging/app_logger.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';

class RecordingBridge implements BackgroundTaskBridge {
  final starts = <String>[];
  final stops = 0;

  var stopped = 0;
  Object? startError;

  @override
  Future<BackgroundTaskStartResult> start({
    required String ownerId,
    required String title,
  }) async {
    if (startError != null) throw startError!;
    starts.add(title);
    return BackgroundTaskStartResult.started;
  }

  @override
  Future<BackgroundTaskStopResult> stop({required String ownerId}) async {
    stopped++;
    return BackgroundTaskStopResult.released;
  }
}

class _StopResultBridge implements BackgroundTaskBridge {
  _StopResultBridge(this.result);

  final BackgroundTaskStopResult result;

  @override
  Future<BackgroundTaskStartResult> start({
    required String ownerId,
    required String title,
  }) async => BackgroundTaskStartResult.started;

  @override
  Future<BackgroundTaskStopResult> stop({required String ownerId}) async =>
      result;
}

void main() {
  test('foreground options leave lifecycle stop to request lease', () {
    expect(
      AndroidForegroundTaskBridge.foregroundTaskOptions().stopWithTask,
      isFalse,
    );
  });

  test('default bridge on non-Android platforms is a no-op', () {
    // The provider chooses per platform; the noop type is part of the public
    // contract for desktop targets.
    expect(const NoopBackgroundTaskBridge(), isA<BackgroundTaskBridge>());
  });

  test('provider container resolves without platform channels', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(backgroundTaskBridgeProvider),
      isA<BackgroundTaskBridge>(),
    );
  });

  test('request title is never passed to foreground notification', () async {
    final conversation = Conversation(
      id: 'conversation',
      title: 'Trip planning',
      modelId: 'model-a',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      messages: const [],
    );

    final request = buildChatStreamRequest(
      conversation,
      'user-1',
      'assistant-1',
      selectedAgentId: null,
      allowedTools: const {},
    );

    String? displayedTitle;
    final bridge = AndroidForegroundTaskBridge(
      isRunning: () async => false,
      startService: (title) async {
        displayedTitle = title;
        return const ServiceRequestSuccess();
      },
      stopService: () async => const ServiceRequestSuccess(),
    );
    await ChatBackgroundLease(
      bridge: bridge,
      publishUnavailable: () {},
    ).acquire(request);

    expect(displayedTitle, AndroidForegroundTaskBridge.notificationTitle);
    expect(displayedTitle, isNot(contains('Trip planning')));
    expect(AndroidForegroundTaskBridge.notificationText, isNotEmpty);
  });

  test('lease diagnostics distinguish every stop outcome', () async {
    final request = buildChatStreamRequest(
      Conversation(
        id: 'conversation',
        title: 'title',
        modelId: 'model',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        messages: const [],
      ),
      'user',
      'assistant',
      selectedAgentId: null,
      allowedTools: const {},
    );
    final statuses = <String?>[];
    for (final result in BackgroundTaskStopResult.values) {
      final logger = AppLogger(sink: (entry) => statuses.add(entry.status));
      await ChatBackgroundLease(
        bridge: _StopResultBridge(result),
        publishUnavailable: () {},
        logger: logger,
      ).release(request);
    }

    expect(statuses, ['released', 'not_running', 'retained_for_retry']);
    expect(statuses, isNot(contains('lease_released')));
  });

  test('returned start failure is unavailable and owns no lease', () async {
    var running = false;
    var stops = 0;
    final bridge = AndroidForegroundTaskBridge(
      isRunning: () async => running,
      startService: (_) async => ServiceRequestFailure(error: StateError('x')),
      stopService: () async {
        stops++;
        return const ServiceRequestSuccess();
      },
    );

    expect(
      await bridge.start(ownerId: 'one', title: 'title'),
      BackgroundTaskStartResult.unavailable,
    );
    await bridge.stop(ownerId: 'one');
    expect(stops, 0);
  });

  test('leases serialize overlapping stop and start', () async {
    var running = false;
    var starts = 0;
    var stops = 0;
    final bridge = AndroidForegroundTaskBridge(
      isRunning: () async => running,
      startService: (_) async {
        starts++;
        running = true;
        return const ServiceRequestSuccess();
      },
      stopService: () async {
        stops++;
        running = false;
        return const ServiceRequestSuccess();
      },
    );

    await bridge.start(ownerId: 'old', title: 'old');
    await bridge.start(ownerId: 'new', title: 'new');
    await bridge.stop(ownerId: 'old');
    expect(running, isTrue);
    expect(stops, 0);
    await bridge.stop(ownerId: 'new');
    expect(starts, 1);
    expect(stops, 1);
  });

  test('returned stop failures retain final lease and retry later', () async {
    var running = true;
    var stops = 0;
    final bridge = AndroidForegroundTaskBridge(
      isRunning: () async => running,
      startService: (_) async => const ServiceRequestSuccess(),
      stopService: () async {
        stops++;
        if (stops < 3) return ServiceRequestFailure(error: StateError('no'));
        running = false;
        return const ServiceRequestSuccess();
      },
      cleanupRetryDelays: const [],
    );
    await bridge.start(ownerId: 'one', title: 'one');

    expect(
      await bridge.stop(ownerId: 'one'),
      BackgroundTaskStopResult.retainedForRetry,
    );
    expect(stops, 2);
    expect(
      await bridge.stop(ownerId: 'one'),
      BackgroundTaskStopResult.released,
    );
    expect(stops, 3);
  });

  test('thrown stop retains lease and next start retries cleanup', () async {
    var running = true;
    var stops = 0;
    var starts = 0;
    final bridge = AndroidForegroundTaskBridge(
      isRunning: () async => running,
      startService: (_) async {
        starts++;
        running = true;
        return const ServiceRequestSuccess();
      },
      stopService: () async {
        stops++;
        if (stops <= 2) throw StateError('channel');
        running = false;
        return const ServiceRequestSuccess();
      },
      cleanupRetryDelays: const [],
    );
    await bridge.start(ownerId: 'one', title: 'one');
    expect(
      await bridge.stop(ownerId: 'one'),
      BackgroundTaskStopResult.retainedForRetry,
    );

    expect(
      await bridge.start(ownerId: 'two', title: 'two'),
      BackgroundTaskStartResult.started,
    );
    expect(stops, 3);
    expect(starts, 1);
  });

  test(
    'scheduled cleanup eventually stops without another bridge call',
    () async {
      var running = true;
      var stops = 0;
      final statuses = <String>[];
      final bridge = AndroidForegroundTaskBridge(
        isRunning: () async => running,
        startService: (_) async => const ServiceRequestSuccess(),
        stopService: () async {
          stops++;
          if (stops < 3) return ServiceRequestFailure(error: StateError('no'));
          running = false;
          return const ServiceRequestSuccess();
        },
        cleanupDelay: (_) async {},
        cleanupRetryDelays: const [Duration.zero],
        onCleanupStatus: statuses.add,
      );
      await bridge.start(ownerId: 'old', title: 'private title');

      expect(
        await bridge.stop(ownerId: 'old'),
        BackgroundTaskStopResult.retainedForRetry,
      );
      await _waitUntil(() => !running);

      expect(stops, 3);
      expect(statuses, contains('cleanup_pending'));
      expect(statuses, isNot(contains('cleanup_exhausted')));
    },
  );

  test('scheduled cleanup exhausts bounded retries', () async {
    var stops = 0;
    final statuses = <String>[];
    final bridge = AndroidForegroundTaskBridge(
      isRunning: () async => true,
      startService: (_) async => const ServiceRequestSuccess(),
      stopService: () async {
        stops++;
        return ServiceRequestFailure(error: StateError('no'));
      },
      cleanupDelay: (_) async {},
      cleanupRetryDelays: const [Duration.zero, Duration.zero],
      onCleanupStatus: statuses.add,
    );
    await bridge.start(ownerId: 'old', title: 'old');
    await bridge.stop(ownerId: 'old');
    await _waitUntil(() => statuses.contains('cleanup_exhausted'));

    expect(stops, 4);
    expect(statuses, ['cleanup_pending', 'cleanup_exhausted']);
  });

  test('stale scheduled cleanup cannot stop a new owner', () async {
    var running = true;
    var stops = 0;
    final delay = Completer<void>();
    final bridge = AndroidForegroundTaskBridge(
      isRunning: () async => running,
      startService: (_) async => const ServiceRequestSuccess(),
      stopService: () async {
        stops++;
        return ServiceRequestFailure(error: StateError('no'));
      },
      cleanupDelay: (_) => delay.future,
      cleanupRetryDelays: const [Duration.zero],
    );
    await bridge.start(ownerId: 'old', title: 'old');
    await bridge.stop(ownerId: 'old');
    expect(
      await bridge.start(ownerId: 'new', title: 'new'),
      BackgroundTaskStartResult.alreadyRunning,
    );
    final beforeStaleRetry = stops;

    delay.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(stops, beforeStaleRetry);
    expect(running, isTrue);
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 20 && !condition(); attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}
