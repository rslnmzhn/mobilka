import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/chat_streaming_coordinator.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart';
import 'package:mobilka/features/chat/data/chat_repository.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_stream_event.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/chat/domain/pending_memory_proposal.dart';

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

  test(
    'does not execute tool calls before an explicit terminal event',
    () async {
      final runtime = _ToolRuntime();
      final fixture = _CoordinatorFixture(
        streamer: _SequencedStreamer(const [
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

  test('does not route update_memory_file through executeTool', () async {
    final runtime = _ToolRuntime();
    final fixture = _CoordinatorFixture(
      events: const [
        ChatStreamEvent(
          toolCallDeltas: [
            ChatToolCallDelta(
              index: 0,
              id: 'call-1',
              name: 'update_memory_file',
              arguments:
                  '{"file_name":"user_profile.md","content":"# User\\nnew\\n"}',
            ),
          ],
        ),
        ChatStreamEvent(finishReason: 'tool_calls', isTerminal: true),
      ],
      toolRuntime: runtime,
    );

    await fixture.run();

    expect(runtime.calls, isEmpty);
    expect(fixture.assistant.status, ChatMessageStatus.interrupted);
  });

  test('persists memory proposal without executing or following up', () async {
    final runtime = _MemoryProposalRuntime();
    final streamer = _SequencedStreamer(const [
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
        ChatStreamEvent(finishReason: 'tool_calls', isTerminal: true),
      ],
    ]);
    final fixture = _CoordinatorFixture(
      streamer: streamer,
      toolRuntime: runtime,
    );

    await fixture.run();

    expect(runtime.executed, isFalse);
    expect(streamer.histories, hasLength(1));
    expect(fixture.conversation.pendingMemoryProposal?.toolCallId, 'call-1');
    expect(fixture.conversation.pendingRequestMessageId, isNotNull);
  });

  test(
    'persists extra call error before waiting for memory decision',
    () async {
      final runtime = _MemoryProposalRuntime();
      final streamer = _SequencedStreamer(const [
        [
          ChatStreamEvent(
            toolCallDeltas: [
              ChatToolCallDelta(
                index: 0,
                id: 'call-memory',
                name: 'update_memory_file',
                arguments: '{}',
              ),
              ChatToolCallDelta(
                index: 1,
                id: 'call-extra',
                name: 'invalid_tool',
                arguments: '{}',
              ),
            ],
          ),
          ChatStreamEvent(finishReason: 'tool_calls', isTerminal: true),
        ],
      ]);
      final fixture = _CoordinatorFixture(
        streamer: streamer,
        toolRuntime: runtime,
      );

      await fixture.run();

      final toolResults = fixture.conversation.messages
          .where((message) => message.role == ChatRole.tool)
          .toList();
      expect(streamer.histories, hasLength(1));
      expect(toolResults.map((message) => message.toolCallId), ['call-extra']);
      expect(toolResults.single.content, contains('awaits confirmation'));
      expect(
        fixture.conversation.pendingMemoryProposal?.toolCallId,
        'call-memory',
      );
    },
  );

  test('persists second memory call error in native call order', () async {
    final runtime = _MemoryProposalRuntime();
    final fixture = _CoordinatorFixture(
      events: const [
        ChatStreamEvent(
          toolCallDeltas: [
            ChatToolCallDelta(
              index: 0,
              id: 'call-1',
              name: 'update_memory_file',
              arguments: '{}',
            ),
            ChatToolCallDelta(
              index: 1,
              id: 'call-2',
              name: 'update_memory_file',
              arguments: '{}',
            ),
          ],
        ),
        ChatStreamEvent(finishReason: 'tool_calls', isTerminal: true),
      ],
      toolRuntime: runtime,
    );

    await fixture.run();

    final assistant = fixture.conversation.messages.firstWhere(
      (message) => message.toolCalls.isNotEmpty,
    );
    final result = fixture.conversation.messages.firstWhere(
      (message) => message.role == ChatRole.tool,
    );
    expect(assistant.toolCalls.map((call) => call.id), ['call-1', 'call-2']);
    expect(result.toolCallId, 'call-2');
    expect(result.content, contains('Only one memory proposal'));
  });

  test(
    'continues persisted memory proposal decision as a tool result',
    () async {
      final streamer = _SequencedStreamer(const [
        [
          ChatStreamEvent(delta: 'Memory decision received.'),
          ChatStreamEvent(finishReason: 'stop', isTerminal: true),
        ],
      ]);
      final fixture = _CoordinatorFixture(streamer: streamer);
      streamer.onStart = () {
        expect(
          fixture.persisted.last.messages.any(
            (message) =>
                message.role == ChatRole.tool && message.toolCallId == 'call-1',
          ),
          isTrue,
        );
      };
      final proposal = PendingMemoryProposal(
        toolCallId: 'call-1',
        assistantMessageId: 'assistant',
        selectedAgentId: 'agent-1',
        allowedTools: const {'update_memory_file'},
        fileName: 'user_profile.md',
        proposedContent: '# User\nFact\n',
        diff: '+Fact',
        confirmationToken: 'token',
        version: 'version',
        createdAt: DateTime.utc(2026),
      );
      fixture.conversations['conversation-1'] = fixture.conversation.copyWith(
        pendingMemoryProposal: proposal,
      );

      await fixture.coordinator.continueAfterMemoryDecision(
        conversation: fixture.conversation,
        proposal: proposal,
        toolResult: '{"ok":false,"rejected":true}',
      );

      expect(fixture.conversation.pendingMemoryProposal, isNull);
      expect(
        fixture.conversation.messages.any(
          (message) =>
              message.role == ChatRole.tool && message.toolCallId == 'call-1',
        ),
        isTrue,
      );
      expect(
        streamer.histories.single.any(
          (message) => message.role == ChatRole.tool,
        ),
        isTrue,
      );
      final firstFollowUp = streamer.histories.single;

      await fixture.coordinator.continueAfterMemoryDecision(
        conversation: fixture.conversation,
        proposal: proposal,
        toolResult: '{"ok":false,"rejected":true}',
      );

      expect(streamer.histories, [firstFollowUp]);
    },
  );

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

  test('executes and follows up a fragmented native tool call', () async {
    final streamer = _SequencedStreamer([
      const [
        ChatStreamEvent(
          toolCallDeltas: [
            ChatToolCallDelta(
              index: 0,
              id: 'call-1',
              name: 'update_memory_file',
              arguments: '{"file_name":"user_',
            ),
          ],
        ),
        ChatStreamEvent(
          finishReason: 'tool_calls',
          isTerminal: true,
          toolCallDeltas: [
            ChatToolCallDelta(
              index: 0,
              arguments: 'profile.md","content":"# User\\n"}',
            ),
          ],
        ),
      ],
      const [
        ChatStreamEvent(delta: 'Saved'),
        ChatStreamEvent(finishReason: 'stop', isTerminal: true),
      ],
    ]);
    final runtime = _ToolRuntime();
    final fixture = _CoordinatorFixture(
      streamer: streamer,
      toolRuntime: runtime,
    );

    await fixture.run();

    expect(runtime.calls.single.name, 'update_memory_file');
    expect(streamer.histories, hasLength(2));
    expect(
      streamer.histories.last.any((message) => message.role == ChatRole.tool),
      isTrue,
    );
    expect(fixture.conversation.messages.last.content, 'Saved');
    expect(fixture.conversation.pendingRequestMessageId, isNull);
  });
}

class _CoordinatorFixture {
  _CoordinatorFixture({
    List<ChatStreamEvent>? events,
    ChatCompletionStreamer? streamer,
    ChatToolRuntime? toolRuntime,
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
      toolRuntime: toolRuntime,
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
      selectedAgentId: 'agent-1',
      allowedTools: const {'update_memory_file'},
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
    List<ChatToolDefinition> tools = const [],
  }) => Stream.fromIterable(events);
}

class _ControlledStreamer implements ChatCompletionStreamer {
  final started = Completer<void>();

  @override
  Stream<ChatStreamEvent> streamCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
    List<ChatToolDefinition> tools = const [],
  }) async* {
    started.complete();
    await cancelToken.whenCancel;
  }
}

class _SequencedStreamer implements ChatCompletionStreamer {
  _SequencedStreamer(this.responses);
  final List<List<ChatStreamEvent>> responses;
  final List<List<ChatMessage>> histories = [];
  void Function()? onStart;

  @override
  Stream<ChatStreamEvent> streamCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
    List<ChatToolDefinition> tools = const [],
  }) {
    onStart?.call();
    histories.add(messages);
    return Stream.fromIterable(responses[histories.length - 1]);
  }
}

class _ToolRuntime implements ChatToolRuntime {
  final List<ChatToolCall> calls = [];

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async => const [
    ChatToolDefinition(
      name: 'update_memory_file',
      description: 'update',
      parameters: {'type': 'object'},
    ),
  ];

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools,
  ) async {
    calls.add(call);
    return '{"ok":true}';
  }
}

class _MemoryProposalRuntime implements ChatToolRuntime, MemoryProposalRuntime {
  var executed = false;

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async => const [];

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools,
  ) async {
    executed = true;
    return '{}';
  }

  @override
  Future<PendingMemoryProposal?> prepareMemoryProposal(
    ChatToolCall call,
    String assistantMessageId,
    String? selectedAgentId,
    Set<String> allowedTools,
  ) async => PendingMemoryProposal(
    toolCallId: call.id,
    assistantMessageId: assistantMessageId,
    selectedAgentId: selectedAgentId!,
    allowedTools: allowedTools,
    fileName: 'user_profile.md',
    proposedContent: '# User\nFact\n',
    diff: '+Fact',
    confirmationToken: 'token',
    version: 'version',
    createdAt: DateTime.utc(2026),
  );

  @override
  Future<void> revalidateMemoryProposal(PendingMemoryProposal proposal) async {}
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
