import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/chat/application/chat_state.dart';
import 'package:mobilka/features/chat/data/conversation_store.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/chat/domain/pending_tool_proposal.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('conversation-recovery-');
    Hive.init(root.path);
    await Hive.openBox<dynamic>('conversations');
  });

  tearDown(() async {
    await Hive.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test(
    'orphan executing proposal interrupts messages and frees admission',
    () async {
      final now = DateTime(2026);
      final proposal = PendingToolProposal(
        conversationId: 'c',
        requestId: 'request',
        assistantMessageId: 'assistant',
        callOccurrence: 0,
        call: const ChatToolCall(
          id: 'call',
          name: 'write_skill',
          arguments: '{}',
        ),
        selectedAgentId: 'agent',
        allowedTools: const {'write_skill'},
        effect: ChatToolEffect.mutating,
        sourceTainted: true,
        permissionSnapshot: null,
        createdAt: now,
        state: PendingToolProposalState.executing,
      );
      final store = ConversationStore();
      await store.save(
        Conversation(
          id: 'c',
          title: 't',
          modelId: 'm',
          createdAt: now,
          updatedAt: now,
          pendingRequestMessageId: 'request',
          pendingToolProposal: proposal,
          messages: [
            ChatMessage(
              id: 'user',
              role: ChatRole.user,
              content: 'x',
              createdAt: now,
              status: ChatMessageStatus.pending,
            ),
            ChatMessage(
              id: 'assistant',
              role: ChatRole.assistant,
              content: '',
              createdAt: now,
              status: ChatMessageStatus.streaming,
            ),
          ],
        ),
      );

      await store.recoverInterrupted();

      final recovered = store.loadAll().single;
      expect(
        recovered.messages.take(2).map((message) => message.status),
        everyElement(ChatMessageStatus.interrupted),
      );
      expect(
        recovered.messages.last.content,
        contains('execution_indeterminate'),
      );
      expect(recovered.pendingRequestMessageId, isNull);
      expect(recovered.pendingToolProposal, isNull);
      expect(recovered.isStreaming, isFalse);
      expect(ChatState(conversations: [recovered]).hasInFlightRequest, isFalse);
    },
  );
}
