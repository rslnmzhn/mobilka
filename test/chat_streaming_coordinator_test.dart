import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/chat_streaming_coordinator.dart';
import 'package:mobilka/features/chat/data/chat_repository.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_stream_event.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';

void main() {
  test('terminal stream completes and clears retry metadata', () async {
    final fixture = _CoordinatorFixture(
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

  test('premature close interrupts and retains retry metadata', () async {
    final fixture = _CoordinatorFixture(
      events: const [ChatStreamEvent(delta: 'Partial')],
    );

    await fixture.run();

    expect(fixture.assistant.status, ChatMessageStatus.interrupted);
    expect(fixture.conversation.pendingRequestMessageId, 'user-1');
    expect(fixture.errors.single, contains('closed before completion'));
  });

  test('cancellation persists interruption before returning', () async {
    final streamer = _ControlledStreamer();
    final fixture = _CoordinatorFixture(streamer: streamer);
    final running = fixture.run();
    await streamer.started.future;

    await fixture.coordinator.cancelAndWait('conversation-1');
    await running;

    expect(fixture.assistant.status, ChatMessageStatus.interrupted);
    expect(fixture.conversation.pendingRequestMessageId, 'user-1');
  });

  test('stream updates remain bound to the captured conversation', () async {
    final fixture = _CoordinatorFixture(
      events: const [
        ChatStreamEvent(delta: 'Bound'),
        ChatStreamEvent(isTerminal: true),
      ],
    );
    fixture.conversations['other'] = _conversation('other');

    await fixture.run();

    expect(
      fixture.conversations['conversation-1']!.messages.last.content,
      'Bound',
    );
    expect(fixture.conversations['other']!.messages, isEmpty);
  });

  test('retry reuses user request and appends only replacement assistant', () {
    final original = _conversation('conversation-1', pending: true).copyWith(
      messages: [
        _conversation('conversation-1', pending: true).messages.first,
        ChatMessage(
          id: 'interrupted-assistant',
          role: ChatRole.assistant,
          content: 'Partial',
          createdAt: DateTime.utc(2026),
          status: ChatMessageStatus.interrupted,
        ),
      ],
    );

    final retry = prepareInterruptedRetry(original, DateTime.utc(2026, 1, 2));

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

class _CoordinatorFixture {
  _CoordinatorFixture({
    List<ChatStreamEvent>? events,
    ChatCompletionStreamer? streamer,
  }) {
    conversations['conversation-1'] = _conversation(
      'conversation-1',
      pending: true,
    );
    coordinator = ChatStreamingCoordinator(
      streamer: streamer ?? _EventStreamer(events ?? const []),
      conversationById: (id) => conversations[id],
      persistAndPublish: (conversation) async {
        persisted.add(conversation);
        conversations[conversation.id] = conversation;
      },
      publishError: errors.add,
    );
  }

  final Map<String, Conversation> conversations = {};
  final List<Conversation> persisted = [];
  final List<String> errors = [];
  late final ChatStreamingCoordinator coordinator;
  Conversation get conversation => conversations['conversation-1']!;
  ChatMessage get assistant => conversation.messages.last;

  Future<void> run() => coordinator.run(
    ChatStreamRequest(
      conversationId: 'conversation-1',
      requestMessageId: 'user-1',
      assistantMessageId: 'assistant-1',
      modelId: 'model',
      history: [conversation.messages.first],
    ),
  );
}

class _EventStreamer implements ChatCompletionStreamer {
  const _EventStreamer(this.events);
  final List<ChatStreamEvent> events;

  @override
  Stream<ChatStreamEvent> streamCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
  }) => Stream.fromIterable(events);
}

class _ControlledStreamer implements ChatCompletionStreamer {
  final started = Completer<void>();

  @override
  Stream<ChatStreamEvent> streamCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
  }) async* {
    started.complete();
    await cancelToken.whenCancel;
  }
}

Conversation _conversation(String id, {bool pending = false}) {
  final now = DateTime.utc(2026);
  return Conversation(
    id: id,
    title: id,
    modelId: 'model',
    createdAt: now,
    updatedAt: now,
    pendingRequestMessageId: pending ? 'user-1' : null,
    messages: pending
        ? [
            ChatMessage(
              id: 'user-1',
              role: ChatRole.user,
              content: 'Question',
              createdAt: now,
            ),
            ChatMessage(
              id: 'assistant-1',
              role: ChatRole.assistant,
              content: '',
              createdAt: now,
              status: ChatMessageStatus.pending,
            ),
          ]
        : const [],
  );
}
