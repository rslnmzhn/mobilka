import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/chat_streaming_coordinator.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_stream_event.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/chat/data/chat_repository.dart';
import 'package:mobilka/features/memory/application/workspace_paths.dart';
import 'package:mobilka/core/logging/app_logger.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime_registry.dart';

import 'support/chat_streaming_coordinator_fakes.dart';

void main() {
  test(
    'thrown background start exception warns and continues request',
    () async {
      final bridge = RecordingBackgroundBridge()
        ..startError = StateError('plugin');
      final fixture = CoordinatorFixture(
        events: const [
          ChatStreamEvent(delta: 'ok'),
          ChatStreamEvent(isTerminal: true),
        ],
        backgroundTasks: bridge,
      );

      await fixture.run();

      expect(fixture.assistant.status, ChatMessageStatus.complete);
      expect(fixture.errors, ['backgroundUnavailable']);
      expect(bridge.stopped, 1);
    },
  );

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

  test('failed optional runtime does not interrupt a normal stream', () async {
    final streamer = _ToolRecordingStreamer();
    final runtime = CompositeChatToolRuntime([
      RegisteredChatToolRuntime(
        'broken',
        () => const _AvailabilityFailureRuntime(),
        failurePolicy: ChatToolRuntimeFailurePolicy.omitOnAvailabilityFailure,
      ),
      RegisteredChatToolRuntime('working', () => const _AvailableRuntime()),
    ]);
    final fixture = CoordinatorFixture(
      streamer: streamer,
      toolRuntime: runtime,
    );

    await fixture.run(allowedTools: const {'working_tool'});

    expect(fixture.assistant.status, ChatMessageStatus.complete);
    expect(streamer.toolNames, ['working_tool']);
  });

  test(
    'failed optional runtime constructor does not interrupt stream',
    () async {
      final streamer = _ToolRecordingStreamer();
      final runtime = CompositeChatToolRuntime([
        RegisteredChatToolRuntime(
          'web_search',
          () => throw UnsupportedError('private constructor detail'),
          failurePolicy: ChatToolRuntimeFailurePolicy.omitOnAvailabilityFailure,
        ),
        RegisteredChatToolRuntime('working', () => const _AvailableRuntime()),
      ]);
      final fixture = CoordinatorFixture(
        streamer: streamer,
        toolRuntime: runtime,
      );

      await fixture.run(allowedTools: const {'working_tool'});

      expect(fixture.assistant.status, ChatMessageStatus.complete);
      expect(streamer.toolNames, ['working_tool']);
    },
  );

  test('failed required runtime interrupts before transport stream', () async {
    final streamer = _ToolRecordingStreamer();
    final runtime = CompositeChatToolRuntime([
      RegisteredChatToolRuntime(
        'memory',
        () => throw UnsupportedError('required constructor'),
      ),
    ]);
    final fixture = CoordinatorFixture(
      streamer: streamer,
      toolRuntime: runtime,
    );

    await fixture.run(allowedTools: const {'working_tool'});

    expect(fixture.assistant.status, ChatMessageStatus.interrupted);
    expect(streamer.toolNames, isEmpty);
  });

  test('logs safe preparation phase for UnsupportedError', () async {
    final logs = <AppLogEntry>[];
    final fixture = CoordinatorFixture(
      streamer: _PreparationFailureStreamer(),
      logger: AppLogger(sink: logs.add),
    );

    await fixture.run();

    final failure = logs.singleWhere(
      (entry) => entry.event == 'chat.streaming',
    );
    expect(failure.phase, 'stream_request.inject_context');
    expect(failure.errorType, 'UnsupportedError');
    expect(failure.errorCode, 'unsupported_operation');
    expect(failure.stackFingerprint, startsWith('sha256:'));
  });

  test(
    'post-success reflection runs once and preserves exact final answer',
    () async {
      final streamer = _RecordingSequencedStreamer(const [
        [
          ChatStreamEvent(
            isTerminal: true,
            finishReason: 'tool_calls',
            toolCallDeltas: [
              ChatToolCallDelta(
                index: 0,
                id: 'material',
                name: 'material_tool',
                arguments: '{}',
              ),
            ],
          ),
        ],
        [ChatStreamEvent(delta: 'Exact answer', isTerminal: true)],
        [ChatStreamEvent(delta: 'internal no-op', isTerminal: true)],
      ]);
      final fixture = CoordinatorFixture(
        streamer: streamer,
        toolRuntime: _ReflectionRuntime(),
      );
      await fixture.run(
        workspaceBinding: const WorkspaceBinding.fakeForTest(),
        allowedTools: const {
          'material_tool',
          'list_skills',
          'read_skill',
          'propose_skill',
        },
      );
      expect(fixture.assistant.content, 'Exact answer');
      expect(fixture.assistant.status, ChatMessageStatus.complete);
      expect(streamer.toolNames.last, {
        'list_skills',
        'read_skill',
        'propose_skill',
      });
      expect(streamer.calls, 3);
    },
  );

  test('pure chat never starts skill reflection', () async {
    final streamer = _RecordingSequencedStreamer(const [
      [ChatStreamEvent(delta: 'Chat only', isTerminal: true)],
    ]);
    final fixture = CoordinatorFixture(
      streamer: streamer,
      toolRuntime: _ReflectionRuntime(),
    );
    await fixture.run(
      allowedTools: const {
        'material_tool',
        'list_skills',
        'read_skill',
        'propose_skill',
      },
    );
    expect(streamer.calls, 1);
    expect(fixture.assistant.content, 'Chat only');
  });

  test(
    'stale terminal finalization does not trigger final-success callback',
    () async {
      late CoordinatorFixture fixture;
      var mutationCount = 0;
      var finalSuccesses = 0;
      fixture = CoordinatorFixture(
        events: const [
          ChatStreamEvent(delta: 'Old response', isTerminal: true),
        ],
        beforePersistMutation: (_) {
          mutationCount++;
          if (mutationCount != 2) return;
          fixture.conversations['conversation-1'] = fixture.conversation
              .copyWith(pendingRequestMessageId: 'user-2');
        },
        onFinalSuccess: (_, _) => finalSuccesses++,
      );

      await fixture.run();

      expect(mutationCount, 2);
      expect(finalSuccesses, 0);
      expect(fixture.conversation.pendingRequestMessageId, 'user-2');
      expect(fixture.assistant.content, 'Old response');
      expect(fixture.assistant.status, ChatMessageStatus.streaming);
    },
  );

  test(
    'transient connection failure before first token is retried once',
    () async {
      final fixture = CoordinatorFixture(
        streamer: SequencedStreamer(const [
          [
            ChatStreamEvent(delta: 'Recovered'),
            ChatStreamEvent(isTerminal: true),
          ],
        ]),
        streamerErrors: [
          DioException(
            type: DioExceptionType.connectionError,
            requestOptions: RequestOptions(path: '/'),
          ),
        ],
      );

      await fixture.run();

      expect(fixture.assistant.status, ChatMessageStatus.complete);
      expect(fixture.assistant.content, 'Recovered');
      expect(fixture.errors, isEmpty);
    },
  );

  test('transient retry is capped at one attempt per request', () async {
    final fixture = CoordinatorFixture(
      streamer: SequencedStreamer(const [
        [ChatStreamEvent(isTerminal: true)],
      ]),
      streamerErrors: [
        DioException(
          type: DioExceptionType.connectionError,
          requestOptions: RequestOptions(path: '/'),
        ),
        DioException(
          type: DioExceptionType.connectionError,
          requestOptions: RequestOptions(path: '/'),
        ),
      ],
    );

    await fixture.run();

    expect(fixture.assistant.status, ChatMessageStatus.interrupted);
    expect(fixture.errors, hasLength(1));
    expect(fixture.errors.single, contains('Could not connect'));
  });

  test(
    'unexpected coordinator errors do not expose raw exception text',
    () async {
      final fixture = CoordinatorFixture(
        streamer: SequencedStreamer(const []),
        streamerErrors: [StateError(r'failed at C:\Users\private\secret.txt')],
      );

      await fixture.run();

      expect(
        fixture.errors.single,
        'The request failed unexpectedly. Please retry.',
      );
      expect(fixture.errors.single, isNot(contains('secret.txt')));
    },
  );

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
    'sequential persona switch and session write share immutable request context',
    () async {
      late CoordinatorFixture fixture;
      final contexts = <ChatToolExecutionContext?>[];
      final runtime = _SequencingRuntime(
        contexts,
        onPersonaSwitch: () {
          final mutable = fixture.conversation;
          fixture.conversations.remove('conversation-1');
          fixture.conversations['conversation-1'] = Conversation(
            id: mutable.id,
            title: 'Replacement active chat',
            modelId: mutable.modelId,
            createdAt: mutable.createdAt,
            updatedAt: mutable.updatedAt,
            messages: mutable.messages,
            pendingRequestMessageId: mutable.pendingRequestMessageId,
            sessionKey: 'replacement-session-key',
          );
          fixture.conversations['other'] = conversationWithId(
            'other',
          ).copyWith(title: 'Active elsewhere');
        },
      );
      fixture = CoordinatorFixture(
        streamer: SequencedStreamer(const [
          [
            ChatStreamEvent(
              toolCallDeltas: [
                ChatToolCallDelta(
                  index: 0,
                  id: 'persona',
                  name: 'switch_persona',
                  arguments: '{"name":"reviewer"}',
                ),
                ChatToolCallDelta(
                  index: 1,
                  id: 'notes',
                  name: 'write_session_notes',
                  arguments: '{"content":"bound notes"}',
                ),
              ],
              isTerminal: true,
              finishReason: 'tool_calls',
            ),
          ],
          [ChatStreamEvent(isTerminal: true)],
        ]),
        toolRuntime: runtime,
      );
      fixture.conversations['conversation-1'] = fixture.conversation.copyWith(
        title: 'Bound title',
      );
      fixture.conversations['conversation-1'] = Conversation(
        id: fixture.conversation.id,
        title: fixture.conversation.title,
        modelId: fixture.conversation.modelId,
        createdAt: fixture.conversation.createdAt,
        updatedAt: fixture.conversation.updatedAt,
        messages: fixture.conversation.messages,
        pendingRequestMessageId: fixture.conversation.pendingRequestMessageId,
        sessionKey: 'bound-session-key',
      );

      await fixture.coordinator.run(
        ChatStreamRequest(
          conversationId: 'conversation-1',
          sessionKey: 'bound-session-key',
          requestMessageId: 'user-1',
          assistantMessageId: 'assistant-1',
          modelId: 'model',
          history: [fixture.conversation.messages.first],
          selectedAgentId: 'agent-1',
          allowedTools: const {'switch_persona', 'write_session_notes'},
        ),
      );

      expect(runtime.calls, ['switch_persona', 'write_session_notes']);
      expect(contexts, hasLength(2));
      expect(
        contexts.every(
          (context) => context?.conversationId == 'conversation-1',
        ),
        isTrue,
      );
      expect(
        contexts.every((context) => context?.sessionKey == 'bound-session-key'),
        isTrue,
      );
    },
  );

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
    expect(result.content, contains('Tool execution failed unexpectedly'));
    expect(result.content, isNot(contains('Unknown tool: unknown_tool')));
    expect(result.toolCallId, startsWith('fallback-'));
  });

  test('strict FormatException tool errors remain actionable', () async {
    final fixture = CoordinatorFixture(
      streamer: SequencedStreamer(const [
        [
          ChatStreamEvent(
            delta: '```json\n{"name":"invalid_tool","arguments":{}}\n```',
            isTerminal: true,
          ),
        ],
        [ChatStreamEvent(isTerminal: true)],
      ]),
      toolRuntime: FormatRejectingToolRuntime(),
    );

    await fixture.run();

    final result = fixture.conversation.messages.firstWhere(
      (message) => message.role == ChatRole.tool,
    );
    expect(result.content, contains('content is required'));
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
        sessionKey: retry.conversation.sessionKey,
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

class _RecordingSequencedStreamer implements ChatCompletionStreamer {
  _RecordingSequencedStreamer(this.responses);
  final List<List<ChatStreamEvent>> responses;
  final List<Set<String>> toolNames = [];
  var calls = 0;

  @override
  Stream<ChatStreamEvent> streamCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
    List<ChatToolDefinition> tools = const [],
  }) {
    toolNames.add(tools.map((tool) => tool.name).toSet());
    return Stream.fromIterable(responses[calls++]);
  }
}

class _AvailabilityFailureRuntime implements ChatToolRuntime {
  const _AvailabilityFailureRuntime();

  @override
  Future<List<ChatToolDefinition>> availableTools(Set<String> allowedTools) {
    throw UnsupportedError('unavailable');
  }

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) async => '';
}

class _AvailableRuntime implements ChatToolRuntime {
  const _AvailableRuntime();
  static const definition = ChatToolDefinition(
    name: 'working_tool',
    description: 'works',
    parameters: {'type': 'object'},
  );

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async => const [definition];

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) async => 'ok';
}

class _ToolRecordingStreamer implements ChatCompletionStreamer {
  List<String> toolNames = const [];

  @override
  Stream<ChatStreamEvent> streamCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
    List<ChatToolDefinition> tools = const [],
  }) async* {
    toolNames = tools.map((tool) => tool.name).toList();
    yield const ChatStreamEvent(delta: 'ok');
    yield const ChatStreamEvent(isTerminal: true);
  }
}

class _PreparationFailureStreamer implements ChatCompletionStreamer {
  @override
  Stream<ChatStreamEvent> streamCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
    List<ChatToolDefinition> tools = const [],
  }) async* {
    final error = UnsupportedError('Cannot modify an unmodifiable list');
    throw ChatPreparationException('inject_context', error, StackTrace.current);
  }
}

class _ReflectionRuntime implements ChatToolRuntime {
  static const definitions = [
    ChatToolDefinition(
      name: 'material_tool',
      description: 'material',
      parameters: {'type': 'object'},
    ),
    ChatToolDefinition(
      effect: ChatToolEffect.readOnly,
      name: 'list_skills',
      description: 'list',
      parameters: {'type': 'object'},
    ),
    ChatToolDefinition(
      effect: ChatToolEffect.readOnly,
      name: 'read_skill',
      description: 'read',
      parameters: {'type': 'object'},
    ),
    ChatToolDefinition(
      effect: ChatToolEffect.runtimeConfirmed,
      name: 'propose_skill',
      description: 'propose',
      parameters: {'type': 'object'},
    ),
  ];

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async =>
      definitions.where((tool) => allowedTools.contains(tool.name)).toList();

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) async => '{"ok":true}';
}

class _SequencingRuntime implements ChatToolRuntime {
  _SequencingRuntime(this.contexts, {required this.onPersonaSwitch});

  final List<ChatToolExecutionContext?> contexts;
  final void Function() onPersonaSwitch;
  final List<String> calls = [];

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async => [
    if (allowedTools.contains('switch_persona'))
      const ChatToolDefinition(
        name: 'switch_persona',
        description: 'switch',
        parameters: {'type': 'object'},
      ),
    if (allowedTools.contains('write_session_notes'))
      const ChatToolDefinition(
        name: 'write_session_notes',
        description: 'write',
        parameters: {'type': 'object'},
      ),
  ];

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) async {
    calls.add(call.name);
    contexts.add(context);
    if (call.name == 'switch_persona') onPersonaSwitch();
    return '{"ok":true}';
  }
}
