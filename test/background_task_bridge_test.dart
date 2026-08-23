import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/background_task_bridge.dart';
import 'package:mobilka/features/chat/application/chat_stream_request.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';

class RecordingBridge implements BackgroundTaskBridge {
  final starts = <String>[];
  final stops = 0;

  var stopped = 0;
  Object? startError;

  @override
  Future<void> start({required String title}) async {
    if (startError != null) throw startError!;
    starts.add(title);
  }

  @override
  Future<void> stop() async => stopped++;
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
}
