import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/chat_state.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/chat/domain/pending_tool_proposal.dart';
import 'package:mobilka/features/chat/domain/pending_memory_proposal.dart';
import 'package:mobilka/features/memory/application/workspace_paths.dart';

void main() {
  test(
    'public-source budget and generic proposal persist backward compatibly',
    () {
      final now = DateTime(2026);
      final conversation = Conversation(
        id: 'c',
        title: 't',
        modelId: 'm',
        createdAt: now,
        updatedAt: now,
        messages: const [],
        publicSourceWireBytesUsed: 42,
        pendingToolProposal: PendingToolProposal(
          conversationId: 'c',
          requestId: 'r',
          assistantMessageId: 'a',
          callOccurrence: 0,
          call: const ChatToolCall(
            id: 'x',
            name: 'write_skill',
            arguments: '{}',
          ),
          selectedAgentId: 'agent',
          allowedTools: {'write_skill'},
          effect: ChatToolEffect.mutating,
          sourceTainted: true,
          permissionSnapshot: null,
          createdAt: now,
        ),
      );
      final restored = Conversation.fromJson(conversation.toJson());
      expect(restored.publicSourceWireBytesUsed, 42);
      expect(restored.pendingToolProposal?.call.arguments, '{}');
      final legacy = conversation.toJson()
        ..remove('publicSourceWireBytesUsed')
        ..remove('pendingToolProposal');
      expect(Conversation.fromJson(legacy).publicSourceWireBytesUsed, 0);
      final negative = conversation.toJson()
        ..['publicSourceWireBytesUsed'] = -1;
      expect(
        Conversation.fromJson(negative).publicSourceWireBytesUsed,
        8 * 1024 * 1024,
      );
    },
  );
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
      pendingMemoryProposal: PendingMemoryProposal(
        toolCallId: 'call-1',
        assistantMessageId: 'assistant-1',
        selectedAgentId: 'agent-1',
        allowedTools: const {'update_memory_file'},
        fileName: 'user.md',
        proposedContent: '# User\nNew fact\n',
        diff: '-old\n+New fact',
        confirmationToken: 'token-1',
        version: 'version-1',
        createdAt: DateTime.utc(2026, 1, 2),
      ),
    );

    final restored = Conversation.fromJson(conversation.toJson());
    expect(restored.id, conversation.id);
    expect(restored.messages.single.content, 'Hello');
    expect(restored.messages.single.status, ChatMessageStatus.complete);
    expect(restored.contextLimitTokens, 32768);
    expect(restored.pendingMemoryProposal?.toolCallId, 'call-1');
    expect(restored.titleState, ConversationTitleState.manual);
    expect(
      restored.pendingMemoryProposal?.proposedContent,
      contains('New fact'),
    );
  });

  test(
    'automatic title state persists and missing legacy titles fall back',
    () {
      final now = DateTime.utc(2026);
      final pending = Conversation(
        id: 'new',
        title: 'question',
        modelId: 'model',
        createdAt: now,
        updatedAt: now,
        messages: const [],
        titleState: ConversationTitleState.pendingAutomatic,
      );
      expect(
        Conversation.fromJson(pending.toJson()).titleState,
        ConversationTitleState.pendingAutomatic,
      );
      final legacy = pending.toJson()..remove('titleState');
      expect(
        Conversation.fromJson(legacy).titleState,
        ConversationTitleState.manual,
      );
      final missingTitle = pending.toJson()
        ..remove('titleState')
        ..remove('title');
      expect(
        Conversation.fromJson(missingTitle).titleState,
        ConversationTitleState.fallback,
      );
      for (final invalid in <Object?>[null, '', '   ', 42]) {
        final json = pending.toJson()
          ..['title'] = invalid
          ..['titleState'] = ConversationTitleState.manual.name;
        final restored = Conversation.fromJson(json);
        expect(restored.title, 'New conversation');
        expect(restored.titleState, ConversationTitleState.fallback);
      }
      for (final state in ConversationTitleState.values) {
        final json = pending.toJson()
          ..['title'] = 'Valid title'
          ..['titleState'] = state.name;
        final restored = Conversation.fromJson(json);
        expect(restored.title, 'Valid title');
        expect(restored.titleState, state);
      }
    },
  );

  test('tool protocol messages round trip through storage', () {
    final assistant = ChatMessage(
      id: 'assistant',
      role: ChatRole.assistant,
      content: '',
      createdAt: DateTime.utc(2026),
      toolCalls: const [
        ChatToolCall(
          id: 'call-1',
          name: 'update_memory_file',
          arguments: '{"file_name":"user.md"}',
        ),
      ],
    );
    final tool = ChatMessage(
      id: 'tool',
      role: ChatRole.tool,
      content: '{"ok":true}',
      createdAt: DateTime.utc(2026),
      toolCallId: 'call-1',
    );

    final restoredAssistant = ChatMessage.fromStorageJson(
      assistant.toStorageJson(),
    );
    final restoredTool = ChatMessage.fromStorageJson(tool.toStorageJson());
    expect(restoredAssistant.toolCalls.single.name, 'update_memory_file');
    expect(restoredTool.toolCallId, 'call-1');
    expect(restoredTool.toJson()['tool_call_id'], 'call-1');
  });

  test('persisted session key survives title rename', () {
    final now = DateTime.utc(2026, 8, 27);
    final conversation = Conversation(
      id: 'conversation-1',
      title: 'Original',
      modelId: 'model',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      sessionKey: 'stable-session-key',
    );

    final renamed = conversation.copyWith(title: 'Renamed');

    expect(renamed.sessionKey, 'stable-session-key');
    expect(
      Conversation.fromJson(renamed.toJson()).sessionKey,
      'stable-session-key',
    );
  });

  test('legacy JSON without sessionKey derives a safe stable key', () {
    final json = <String, dynamic>{
      'id': 'legacy-conversation',
      'title': 'Legacy title',
      'modelId': 'model',
      'createdAt': DateTime.utc(2026, 8, 27).toIso8601String(),
      'updatedAt': DateTime.utc(2026, 8, 27).toIso8601String(),
      'messages': <Object?>[],
    };

    final restored = Conversation.fromJson(json);

    expect(restored.sessionKey, isNotNull);
    expect(restored.sessionKey?.toLowerCase(), contains('legacy_title'));
    expect(
      restored.sessionKey,
      WorkspaceStore.sessionKey(
        createdAt: restored.createdAt,
        title: restored.title,
        conversationId: restored.id,
      ),
    );
  });

  test(
    'reasoning content round trips through storage and stays off the wire',
    () {
      final message = ChatMessage(
        id: 'assistant-reasoning',
        role: ChatRole.assistant,
        content: 'Answer',
        createdAt: DateTime.utc(2026),
        reasoningContent: 'thinking hard',
      );

      final restored = ChatMessage.fromStorageJson(message.toStorageJson());
      expect(restored.reasoningContent, 'thinking hard');

      final wire = message.toJson();
      // Reasoning is display-only: it must never be sent to the provider.
      expect(wire.containsKey('reasoning_content'), isFalse);
      expect(wire['content'], 'Answer');
    },
  );

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
