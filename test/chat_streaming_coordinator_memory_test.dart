import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart'
    as chat_runtime;
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_stream_event.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/chat/domain/pending_memory_proposal.dart';
import 'package:mobilka/features/memory/application/workspace_paths.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';
import 'package:saf/saf.dart';

import 'support/chat_streaming_coordinator_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mobilka-binding');
    Hive.init('${root.path}/hive');
    await Hive.openBox<dynamic>('preferences');
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk('preferences');
    await Hive.close();
    await root.delete(recursive: true);
  });

  test(
    'fallback update_memory_file persists proposal without mutation',
    () async {
      final runtime = MemoryProposalRuntime();
      final fixture = CoordinatorFixture(
        events: const [
          ChatStreamEvent(
            delta:
                '```tool_call\n{"name":"update_memory_file","arguments":{"file_name":"user.md","content":"# New"}}\n```',
            isTerminal: true,
            finishReason: 'stop',
          ),
        ],
        toolRuntime: runtime,
      );

      await fixture.run();

      expect(runtime.executed, isFalse);
      expect(fixture.conversation.pendingMemoryProposal, isNotNull);
      expect(
        fixture.conversation.pendingMemoryProposal!.toolCallId,
        startsWith('fallback-'),
      );
      expect(fixture.conversation.messages[1].content, isEmpty);
      expect(fixture.conversation.messages[1].toolCalls, hasLength(1));
      expect(fixture.conversation.messages, hasLength(2));
    },
  );

  test('does not route update_memory_file through executeTool', () async {
    final runtime = ToolRuntime();
    final fixture = CoordinatorFixture(
      events: const [
        ChatStreamEvent(
          toolCallDeltas: [
            ChatToolCallDelta(
              index: 0,
              id: 'call-1',
              name: 'update_memory_file',
              arguments: '{"file_name":"user.md","content":"# User\\nnew\\n"}',
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
    final runtime = MemoryProposalRuntime();
    final streamer = SequencedStreamer(const [
      [
        ChatStreamEvent(
          toolCallDeltas: [
            ChatToolCallDelta(
              index: 0,
              id: 'call-1',
              name: 'update_memory_file',
              arguments: '{"file_name":"user.md","content":"# User\\nnew\\n"}',
            ),
          ],
        ),
        ChatStreamEvent(finishReason: 'tool_calls', isTerminal: true),
      ],
    ]);
    final fixture = CoordinatorFixture(
      streamer: streamer,
      toolRuntime: runtime,
    );

    await fixture.run();

    expect(runtime.executed, isFalse);
    expect(streamer.histories, hasLength(1));
    expect(
      fixture.persisted.where(
        (snapshot) => snapshot.pendingMemoryProposal?.toolCallId == 'call-1',
      ),
      hasLength(1),
    );
    expect(fixture.conversation.pendingMemoryProposal?.toolCallId, 'call-1');
    expect(fixture.conversation.pendingRequestMessageId, isNotNull);
  });

  test(
    'persists extra call error before waiting for memory decision',
    () async {
      final runtime = MemoryProposalRuntime();
      final streamer = SequencedStreamer(const [
        [
          ChatStreamEvent(
            toolCallDeltas: [
              ChatToolCallDelta(
                index: 0,
                id: 'call-memory',
                name: 'update_memory_file',
                arguments:
                    '{"file_name":"user.md","content":"# User\\nnew\\n"}',
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
      final fixture = CoordinatorFixture(
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
    final runtime = MemoryProposalRuntime();
    final fixture = CoordinatorFixture(
      events: const [
        ChatStreamEvent(
          toolCallDeltas: [
            ChatToolCallDelta(
              index: 0,
              id: 'call-1',
              name: 'update_memory_file',
              arguments: '{"file_name":"user.md","content":"# User\\none\\n"}',
            ),
            ChatToolCallDelta(
              index: 1,
              id: 'call-2',
              name: 'update_memory_file',
              arguments: '{"file_name":"user.md","content":"# User\\ntwo\\n"}',
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
      final streamer = SequencedStreamer(const [
        [
          ChatStreamEvent(delta: 'Memory decision received.'),
          ChatStreamEvent(finishReason: 'stop', isTerminal: true),
        ],
      ]);
      final fixture = CoordinatorFixture(streamer: streamer);
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
        fileName: 'user.md',
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

  test(
    'changed proposal and request before queued decision mutation do not continue',
    () async {
      final streamer = SequencedStreamer(const [
        [ChatStreamEvent(delta: 'must not run', isTerminal: true)],
      ]);
      late CoordinatorFixture fixture;
      var mutateBeforePersist = false;
      fixture = CoordinatorFixture(
        streamer: streamer,
        beforePersistMutation: (_) {
          if (!mutateBeforePersist) return;
          mutateBeforePersist = false;
          final latest = fixture.conversation;
          fixture.conversations['conversation-1'] = latest.copyWith(
            pendingRequestMessageId: 'user-2',
            pendingMemoryProposal: PendingMemoryProposal(
              toolCallId: 'call-new',
              assistantMessageId: 'assistant-new',
              selectedAgentId: 'agent-1',
              allowedTools: const {'update_memory_file'},
              fileName: 'user.md',
              proposedContent: '# Changed\n',
              diff: '+Changed',
              confirmationToken: 'new-token',
              version: 'new-version',
              createdAt: DateTime.utc(2026, 1, 2),
            ),
          );
        },
      );
      final proposal = PendingMemoryProposal(
        toolCallId: 'call-1',
        assistantMessageId: 'assistant-1',
        selectedAgentId: 'agent-1',
        allowedTools: const {'update_memory_file'},
        fileName: 'user.md',
        proposedContent: '# User\nFact\n',
        diff: '+Fact',
        confirmationToken: 'token',
        version: 'version',
        createdAt: DateTime.utc(2026),
      );
      fixture.conversations['conversation-1'] = fixture.conversation.copyWith(
        pendingMemoryProposal: proposal,
      );
      final staleSnapshot = fixture.conversation;
      final originalMessageIds = staleSnapshot.messages
          .map((message) => message.id)
          .toList();
      mutateBeforePersist = true;

      await fixture.coordinator.continueAfterMemoryDecision(
        conversation: staleSnapshot,
        proposal: proposal,
        toolResult: '{"ok":true}',
      );

      expect(streamer.histories, isEmpty);
      expect(fixture.conversation.pendingRequestMessageId, 'user-2');
      expect(
        fixture.conversation.pendingMemoryProposal?.toolCallId,
        'call-new',
      );
      expect(
        fixture.conversation.messages.map((message) => message.id),
        originalMessageIds,
      );
      expect(
        fixture.conversation.messages.where(
          (message) => message.role == ChatRole.tool,
        ),
        isEmpty,
      );
    },
  );

  test(
    'security-bound proposal replacement before queued decision does not continue',
    () async {
      final streamer = SequencedStreamer(const [
        [ChatStreamEvent(delta: 'must not run', isTerminal: true)],
      ]);
      late CoordinatorFixture fixture;
      var replaceBeforePersist = false;
      final proposal = PendingMemoryProposal(
        toolCallId: 'call-1',
        assistantMessageId: 'assistant-1',
        callOccurrence: 0,
        selectedAgentId: 'agent-1',
        allowedTools: const {'update_memory_file'},
        fileName: 'user.md',
        proposedContent: '# User\nFact\n',
        diff: '+Fact',
        confirmationToken: 'token',
        version: 'version',
        createdAt: DateTime.utc(2026),
      );
      fixture = CoordinatorFixture(
        streamer: streamer,
        beforePersistMutation: (_) {
          if (!replaceBeforePersist) return;
          replaceBeforePersist = false;
          final latest = fixture.conversation;
          fixture.conversations['conversation-1'] = latest.copyWith(
            pendingMemoryProposal: PendingMemoryProposal(
              toolCallId: proposal.toolCallId,
              assistantMessageId: proposal.assistantMessageId,
              callOccurrence: proposal.callOccurrence,
              selectedAgentId: proposal.selectedAgentId,
              allowedTools: proposal.allowedTools,
              fileName: proposal.fileName,
              proposedContent: '# User\nReplacement\n',
              diff: '+Replacement',
              confirmationToken: 'replacement-token',
              version: 'replacement-version',
              createdAt: proposal.createdAt,
            ),
          );
        },
      );
      fixture.conversations['conversation-1'] = fixture.conversation.copyWith(
        pendingMemoryProposal: proposal,
      );
      final staleSnapshot = fixture.conversation;
      final originalMessageIds = staleSnapshot.messages
          .map((message) => message.id)
          .toList();
      replaceBeforePersist = true;

      await fixture.coordinator.continueAfterMemoryDecision(
        conversation: staleSnapshot,
        proposal: proposal,
        toolResult: '{"ok":true}',
      );

      final replacement = fixture.conversation.pendingMemoryProposal!;
      expect(streamer.histories, isEmpty);
      expect(fixture.conversation.pendingRequestMessageId, 'user-1');
      expect(replacement.toolCallId, proposal.toolCallId);
      expect(replacement.assistantMessageId, proposal.assistantMessageId);
      expect(replacement.callOccurrence, proposal.callOccurrence);
      expect(replacement.confirmationToken, 'replacement-token');
      expect(replacement.version, 'replacement-version');
      expect(replacement.proposedContent, contains('Replacement'));
      expect(
        fixture.conversation.messages.map((message) => message.id),
        originalMessageIds,
      );
      expect(
        fixture.conversation.messages.where(
          (message) => message.role == ChatRole.tool,
        ),
        isEmpty,
      );
    },
  );

  test('persists a fragmented memory call pending confirmation', () async {
    final streamer = SequencedStreamer([
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
    final runtime = MemoryProposalRuntime();
    final fixture = CoordinatorFixture(
      streamer: streamer,
      toolRuntime: runtime,
    );

    await fixture.run();

    expect(runtime.executed, isFalse);
    expect(streamer.histories, hasLength(1));
    expect(fixture.conversation.pendingMemoryProposal?.toolCallId, 'call-1');
    expect(fixture.conversation.pendingRequestMessageId, isNotNull);
  });

  for (final decision in ['confirmation', 'rejection']) {
    test(
      '$decision continuation generate_docx keeps original workspace binding',
      () async {
        final original = Directory('${root.path}/original')..createSync();
        final changed = Directory('${root.path}/changed')..createSync();
        final binding = await _bindingFor(original);
        final runtime = _MemoryThenDocxRuntime();
        final fixture = CoordinatorFixture(
          streamer: _memoryThenDocxStreamer(),
          toolRuntime: runtime,
        );

        await fixture.run(workspaceBinding: binding);
        await Hive.box<dynamic>(
          'preferences',
        ).put('memoryLocation', changed.path);
        final proposal = fixture.conversation.pendingMemoryProposal!;
        await fixture.coordinator.continueAfterMemoryDecision(
          conversation: fixture.conversation,
          proposal: proposal,
          toolResult: decision == 'confirmation'
              ? '{"ok":true}'
              : '{"ok":false,"rejected":true}',
        );

        expect(runtime.docxBindings, [same(binding)]);
        expect(
          fixture.coordinator.retainedWorkspaceBindingForRetry(
            'conversation-1',
            'user-1',
          ),
          isNull,
        );
      },
    );
  }

  test(
    'recreated coordinator fails safe instead of using current workspace',
    () async {
      final original = Directory('${root.path}/original')..createSync();
      final changed = Directory('${root.path}/changed')..createSync();
      final binding = await _bindingFor(original);
      final first = CoordinatorFixture(
        streamer: SequencedStreamer([_memoryProposalEvents]),
        toolRuntime: _MemoryThenDocxRuntime(),
      );
      await first.run(workspaceBinding: binding);
      await Hive.box<dynamic>(
        'preferences',
      ).put('memoryLocation', changed.path);

      final runtime = _MemoryThenDocxRuntime();
      final recreated = CoordinatorFixture(
        streamer: SequencedStreamer([_docxEvents, _completeEvents]),
        toolRuntime: runtime,
      );
      recreated.conversations['conversation-1'] = first.conversation;
      final proposal = recreated.conversation.pendingMemoryProposal!;
      await recreated.coordinator.continueAfterMemoryDecision(
        conversation: recreated.conversation,
        proposal: proposal,
        toolResult: '{"ok":true}',
      );

      expect(runtime.docxBindings, [isNull]);
      expect(runtime.docxResults, contains('{"workspace_saved":false}'));
    },
  );

  test('conversation deletion removes retained workspace binding', () async {
    final binding = await _bindingFor(
      Directory('${root.path}/original')..createSync(),
    );
    final runtime = _MemoryThenDocxRuntime();
    final fixture = CoordinatorFixture(
      streamer: _memoryThenDocxStreamer(),
      toolRuntime: runtime,
    );
    await fixture.run(workspaceBinding: binding);
    fixture.coordinator.forgetConversation('conversation-1');
    expect(
      fixture.coordinator.retainedWorkspaceBindingForRetry(
        'conversation-1',
        'user-1',
      ),
      isNull,
    );
    final proposal = fixture.conversation.pendingMemoryProposal!;

    await fixture.coordinator.continueAfterMemoryDecision(
      conversation: fixture.conversation,
      proposal: proposal,
      toolResult: '{"ok":false,"rejected":true}',
    );

    expect(runtime.docxBindings, [isNull]);
  });
}

const _memoryProposalEvents = [
  ChatStreamEvent(
    toolCallDeltas: [
      ChatToolCallDelta(
        index: 0,
        id: 'call-memory',
        name: 'update_memory_file',
        arguments: '{"file_name":"user.md","content":"new"}',
      ),
    ],
  ),
  ChatStreamEvent(finishReason: 'tool_calls', isTerminal: true),
];
const _docxEvents = [
  ChatStreamEvent(
    toolCallDeltas: [
      ChatToolCallDelta(
        index: 0,
        id: 'call-docx',
        name: 'generate_docx',
        arguments: '{"title":"Report","markdown":"body"}',
      ),
    ],
  ),
  ChatStreamEvent(finishReason: 'tool_calls', isTerminal: true),
];
const _completeEvents = [
  ChatStreamEvent(finishReason: 'stop', isTerminal: true),
];

SequencedStreamer _memoryThenDocxStreamer() =>
    SequencedStreamer([_memoryProposalEvents, _docxEvents, _completeEvents]);

Future<WorkspaceBinding> _bindingFor(Directory directory) async {
  final preferences = Hive.box<dynamic>('preferences');
  await preferences.put('memoryLocation', directory.path);
  await preferences.put('memoryLocationIsUri', false);
  final repository = MemoryRepository(
    Saf(),
    boundaryFactory: (_) => PathMemoryFileStore(directory.path),
  );
  return WorkspaceStore(repository: repository).captureBinding()!;
}

class _MemoryThenDocxRuntime extends MemoryProposalRuntime {
  final List<WorkspaceBinding?> docxBindings = [];
  final List<String> docxResults = [];

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async => const [
    ChatToolDefinition(
      name: 'generate_docx',
      description: 'generate',
      parameters: {'type': 'object'},
    ),
  ];

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    chat_runtime.ChatToolExecutionContext? context,
  }) async {
    docxBindings.add(context?.workspaceBinding);
    final result = context?.workspaceBinding == null
        ? '{"workspace_saved":false}'
        : '{"workspace_saved":true}';
    docxResults.add(result);
    return result;
  }
}
