import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/chat_state.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';

void main() {
  test('conversation round trips through Hive-compatible maps', () {
    final conversation = Conversation(
      id: 'conversation-1',
      title: 'Hello',
      modelId: 'model-1',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026, 1, 2),
      messages: [
        ChatMessage(
          id: 'message-1',
          role: ChatRole.user,
          content: 'Hello',
          createdAt: DateTime.utc(2026),
        ),
      ],
    );

    final restored = Conversation.fromJson(conversation.toJson());
    expect(restored.id, conversation.id);
    expect(restored.messages.single.content, 'Hello');
    expect(restored.messages.single.status, ChatMessageStatus.complete);
    expect(restored.contextLimitTokens, 32768);
  });

  test('pending message can be marked interrupted after restart', () {
    final message = ChatMessage(
      id: 'message-1',
      role: ChatRole.assistant,
      content: 'Partial',
      createdAt: DateTime.utc(2026),
      status: ChatMessageStatus.pending,
    );
    expect(
      message.copyWith(status: ChatMessageStatus.interrupted).status,
      ChatMessageStatus.interrupted,
    );
  });

  test('streaming and usage are scoped to each persisted conversation', () {
    final now = DateTime.utc(2026);
    final streaming = Conversation(
      id: 'streaming',
      title: 'Streaming',
      modelId: 'model',
      createdAt: now,
      updatedAt: now,
      usage: const ConversationUsage(totalTokens: 8),
      messages: [
        ChatMessage(
          id: 'assistant',
          role: ChatRole.assistant,
          content: 'Partial',
          createdAt: now,
          status: ChatMessageStatus.streaming,
        ),
      ],
    );
    final idle = Conversation(
      id: 'idle',
      title: 'Idle',
      modelId: 'model',
      createdAt: now,
      updatedAt: now,
      messages: const [],
    );

    final state = ChatState(
      conversations: [streaming, idle],
      activeConversationId: 'idle',
    );

    expect(state.isStreaming, isFalse);
    expect(state.hasInFlightRequest, isTrue);
    expect(state.activeConversation?.usage, isNull);
    expect(
      state.copyWith(activeConversationId: 'streaming').isStreaming,
      isTrue,
    );
  });
}
