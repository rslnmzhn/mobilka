import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_stream_event.dart';
import 'package:mobilka/features/chat/domain/pending_memory_proposal.dart';

import 'support/chat_streaming_coordinator_fakes.dart';

void main() {
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
    final runtime = MemoryProposalRuntime();
    final streamer = SequencedStreamer(const [
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
}
