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

  test('executes fallback calls only after explicit terminal event', () async {
    final runtime = ToolRuntime();
    final fixture = CoordinatorFixture(
      streamer: SequencedStreamer(const [
        [
          ChatStreamEvent(
            delta:
                'Visible\n```json\n{"name":"other_tool","arguments":{"b":2,"a":1}}\n```',
            isTerminal: true,
            finishReason: 'stop',
          ),
        ],
        [ChatStreamEvent(delta: 'Finished', isTerminal: true)],
      ]),
      toolRuntime: runtime,
    );

    await fixture.run();

    expect(runtime.calls, hasLength(1));
    expect(runtime.calls.single.name, 'other_tool');
    expect(runtime.calls.single.arguments, '{"a":1,"b":2}');
    expect(fixture.conversation.messages[1].content, 'Visible');
    expect(fixture.assistant.content, 'Finished');
    expect(fixture.assistant.status, ChatMessageStatus.complete);
  });

  test(
    'does not parse fallback text without explicit terminal event',
    () async {
      final runtime = ToolRuntime();
      final fixture = CoordinatorFixture(
        events: const [
          ChatStreamEvent(
            delta: '```json\n{"name":"other_tool","arguments":{}}\n```',
          ),
        ],
        toolRuntime: runtime,
      );

      await fixture.run();

      expect(runtime.calls, isEmpty);
      expect(fixture.assistant.status, ChatMessageStatus.interrupted);
    },
  );

  test('any native tool delta prevents fallback parsing', () async {
    final runtime = ToolRuntime();
    final fallback = '```json\n{"name":"fallback_tool","arguments":{}}\n```';
    final fixture = CoordinatorFixture(
      events: [
        ChatStreamEvent(
          delta: fallback,
          toolCallDeltas: const [
            ChatToolCallDelta(
              index: 0,
              id: 'partial-native',
              name: 'native_tool',
              arguments: '{',
            ),
          ],
        ),
        const ChatStreamEvent(isTerminal: true, finishReason: 'stop'),
      ],
      toolRuntime: runtime,
    );

    await fixture.run();

    expect(runtime.calls, isEmpty);
    expect(fixture.assistant.content, fallback);
    expect(fixture.assistant.status, ChatMessageStatus.complete);
  });

  test('unknown fallback tool is persisted as a non-mutating error', () async {
    final runtime = RejectingToolRuntime();
    final fixture = CoordinatorFixture(
      streamer: SequencedStreamer(const [
        [
          ChatStreamEvent(
            delta: '```json\n{"name":"unknown_tool","arguments":{}}\n```',
            isTerminal: true,
          ),
        ],
        [ChatStreamEvent(isTerminal: true)],
      ]),
      toolRuntime: runtime,
    );

    await fixture.run();

    final result = fixture.conversation.messages.firstWhere(
      (message) => message.role == ChatRole.tool,
    );
    expect(runtime.calls.single.name, 'unknown_tool');
    expect(result.content, contains('Unknown tool: unknown_tool'));
    expect(result.toolCallId, startsWith('fallback-'));
  });

  test('persisted synthetic fallback call is not executed on retry', () async {
    final runtime = ToolRuntime();
    const fallback = '```json\n{"name":"other_tool","arguments":{}}\n```';
    final first = CoordinatorFixture(
      streamer: SequencedStreamer(const [
        [ChatStreamEvent(delta: fallback, isTerminal: true)],
        [ChatStreamEvent(isTerminal: true)],
      ]),
      toolRuntime: runtime,
    );
    await first.run();
    final persistedCall = first.conversation.messages[1].toolCalls.single;

    final retry = CoordinatorFixture(
      events: const [ChatStreamEvent(delta: fallback, isTerminal: true)],
      toolRuntime: runtime,
    );
    retry.conversations['conversation-1'] = first.conversation.copyWith(
      pendingRequestMessageId: 'user-1',
      messages: [
        ...first.conversation.messages,
        ChatMessage(
          id: 'assistant-retry',
          role: ChatRole.assistant,
          content: '',
          createdAt: DateTime(2025),
          status: ChatMessageStatus.pending,
        ),
      ],
    );
    await retry.coordinator.run(
      ChatStreamRequest(
        conversationId: 'conversation-1',
        requestMessageId: 'user-1',
        assistantMessageId: 'assistant-retry',
        modelId: 'model',
        history: const [],
        selectedAgentId: 'agent-1',
        allowedTools: const {'update_memory_file'},
      ),
    );

    expect(persistedCall.id, startsWith('fallback-'));
    expect(runtime.calls, hasLength(1));
  });

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
