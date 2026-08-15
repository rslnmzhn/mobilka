import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/chat_streaming_coordinator.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_stream_event.dart';

import 'support/chat_streaming_coordinator_fakes.dart';

void main() {
  test('terminal stream completes and clears retry metadata', () async {
    final fixture = CoordinatorFixture(
      events: const [
        ChatStreamEvent(delta: 'Hello'),
        ChatStreamEvent(isTerminal: true, usage: ChatUsage(totalTokens: 5)),
      ],
    );

    await fixture.run();

    expect(fixture.assistant.status, ChatMessageStatus.complete);
    expect(fixture.conversation.pendingRequestMessageId, isNull);
    expect(fixture.conversation.usage?.totalTokens, 5);
    expect(fixture.errors, isEmpty);
  });

  test(
    'does not execute tool calls before an explicit terminal event',
    () async {
      final runtime = ToolRuntime();
      final fixture = CoordinatorFixture(
        streamer: SequencedStreamer(const [
          [
            ChatStreamEvent(
              toolCallDeltas: [
                ChatToolCallDelta(
                  index: 0,
                  id: 'call-1',
                  name: 'update_memory_file',
                  arguments: '{}',
                ),
              ],
            ),
            ChatStreamEvent(finishReason: 'tool_calls'),
          ],
        ]),
        toolRuntime: runtime,
      );

      await fixture.run();

      expect(runtime.calls, isEmpty);
      expect(fixture.assistant.status, ChatMessageStatus.interrupted);
      expect(fixture.conversation.pendingRequestMessageId, 'user-1');
    },
  );

  test('premature close interrupts and retains retry metadata', () async {
    final fixture = CoordinatorFixture(
      events: const [ChatStreamEvent(delta: 'Partial')],
    );

    await fixture.run();

    expect(fixture.assistant.status, ChatMessageStatus.interrupted);
    expect(fixture.conversation.pendingRequestMessageId, 'user-1');
    expect(fixture.errors.single, contains('closed before completion'));
  });

  test('cancellation persists interruption before returning', () async {
    final streamer = ControlledStreamer();
    final fixture = CoordinatorFixture(streamer: streamer);
    final running = fixture.run();
    await streamer.started.future;

    await fixture.coordinator.cancelAndWait('conversation-1');
    await running;

    expect(fixture.assistant.status, ChatMessageStatus.interrupted);
    expect(fixture.conversation.pendingRequestMessageId, 'user-1');
  });

  test('stream updates remain bound to the captured conversation', () async {
    final fixture = CoordinatorFixture(
      events: const [
        ChatStreamEvent(delta: 'Bound'),
        ChatStreamEvent(isTerminal: true),
      ],
    );
    fixture.conversations['other'] = conversationWithId('other');

    await fixture.run();

    expect(
      fixture.conversations['conversation-1']!.messages.last.content,
      'Bound',
    );
    expect(fixture.conversations['other']!.messages, isEmpty);
  });

  test('retry reuses user request and appends only replacement assistant', () {
    final original = conversationWithId('conversation-1', pending: true)
        .copyWith(
          messages: [
            conversationWithId('conversation-1', pending: true).messages.first,
            ChatMessage(
              id: 'interrupted-assistant',
              role: ChatRole.assistant,
              content: 'Partial',
              createdAt: DateTime.utc(2026),
              status: ChatMessageStatus.interrupted,
            ),
          ],
        );

    final retry = prepareInterruptedRetry(
      original,
      DateTime.utc(2026, 1, 2),
      selectedAgentId: 'agent-1',
      allowedTools: const {'update_memory_file'},
    );

    expect(retry, isNotNull);
    expect(
      retry!.conversation.messages.where(
        (message) => message.role == ChatRole.user,
      ),
      hasLength(1),
    );
    expect(
      retry.conversation.messages,
      hasLength(original.messages.length + 1),
    );
    expect(retry.conversation.messages.last.status, ChatMessageStatus.pending);
    expect(retry.request.history.map((message) => message.id), ['user-1']);
  });
}
