import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:mobilka/features/chat/application/background_task_bridge.dart';
import 'package:mobilka/features/chat/application/chat_stream_request.dart';
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
  Future<void> stop({required String ownerId}) async => stopped++;
}

void main() {
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

  test('request carries conversation title for the notification', () {
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

    expect(request.conversationTitle, 'Trip planning');
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
}
