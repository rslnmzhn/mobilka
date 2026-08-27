import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/pending_workspace_binding_store.dart';
import 'package:mobilka/features/chat/domain/chat_stream_event.dart';
import 'package:mobilka/features/memory/application/workspace_paths.dart';

import 'support/chat_streaming_coordinator_fakes.dart';

void main() {
  test(
    'pending decision survives service refresh and terminal cleanup',
    () async {
      final bindings = PendingWorkspaceBindingStore();
      const binding = WorkspaceBinding.fakeForTest();
      final first = CoordinatorFixture(
        streamer: SequencedStreamer([_memoryProposalEvents]),
        toolRuntime: MemoryProposalRuntime(),
        workspaceBindings: bindings,
      );
      await first.run(workspaceBinding: binding);
      final proposal = first.conversation.pendingMemoryProposal!;
      first.coordinator.dispose();

      final second = CoordinatorFixture(
        streamer: SequencedStreamer([_completeEvents]),
        workspaceBindings: bindings,
      );
      second.conversations['conversation-1'] = first.conversation;
      await second.coordinator.continueAfterMemoryDecision(
        conversation: second.conversation,
        proposal: proposal,
        toolResult: '{"ok":false,"rejected":true}',
      );

      expect(
        second.coordinator.retainedWorkspaceBindingForRetry(
          'conversation-1',
          'user-1',
        ),
        isNull,
      );
      second.coordinator.dispose();
      bindings.reset();
    },
  );
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

const _completeEvents = [
  ChatStreamEvent(finishReason: 'stop', isTerminal: true),
];
