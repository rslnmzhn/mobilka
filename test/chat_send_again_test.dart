import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/agents/application/agents_controller.dart';
import 'package:mobilka/features/agents/domain/agent_catalog.dart';
import 'package:mobilka/features/chat/application/chat_controller.dart';
import 'package:mobilka/features/chat/data/chat_repository.dart';
import 'package:mobilka/features/chat/data/conversation_store.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_stream_event.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/chat/domain/pending_memory_proposal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chat-send-again-');
    Hive.init(root.path);
    await Hive.openBox<dynamic>('conversations');
    await Hive.openBox<dynamic>('preferences');
  });

  tearDown(() async {
    await Hive.close();
    await root.delete(recursive: true);
  });

  Future<ProviderContainer> bootstrap(
    List<Conversation> conversations,
    ChatCompletionStreamer streamer,
  ) async {
    for (final conversation in conversations) {
      await ConversationStore().save(conversation);
    }
    final container = ProviderContainer(
      overrides: [
        agentsControllerProvider.overrideWith(_EmptyAgentsController.new),
        chatCompletionStreamerProvider.overrideWithValue(streamer),
      ],
    );
    addTearDown(container.dispose);
    await container.read(chatControllerProvider.future);
    return container;
  }

  test(
    'identity-bound resend appends and preserves all existing history',
    () async {
      final streamer = _RecordingStreamer();
      final target = _conversation('target', model: 'text-model');
      final other = _conversation('other', model: 'other-model', newer: true);
      final container = await bootstrap([target, other], streamer);
      final controller = container.read(chatControllerProvider.notifier);
      expect(
        container
            .read(chatControllerProvider)
            .requireValue
            .activeConversationId,
        'other',
      );

      await controller.sendAgain('target', 'original-user');

      final state = container.read(chatControllerProvider).requireValue;
      expect(state.activeConversationId, 'other');
      final updated = state.conversationById('target')!;
      expect(updated.messages.take(3).map((message) => message.id), [
        'original-user',
        'following-assistant',
        'following-user',
      ]);
      expect(updated.messages.length, 5);
      expect(updated.messages[3].role, ChatRole.user);
      expect(updated.messages[3].content, 'send exactly this');
      expect(updated.messages[4].role, ChatRole.assistant);
      expect(updated.messages[4].content, 'done');
      expect(streamer.models, ['text-model']);
      expect(streamer.persistedBeforeStart, isTrue);
      expect(streamer.histories.single.last.content, 'send exactly this');
      expect(streamer.histories.single.last.id, isNot('original-user'));
    },
  );

  test(
    'attachments are revalidated against current conversation model',
    () async {
      final streamer = _RecordingStreamer();
      final container = await bootstrap([
        _conversation('target', model: 'text-model'),
      ], streamer);

      await container
          .read(chatControllerProvider.notifier)
          .sendAgain('target', 'original-user');

      final resent = container
          .read(chatControllerProvider)
          .requireValue
          .conversationById('target')!
          .messages[3];
      expect(resent.attachments.map((item) => item.name), ['notes.txt']);
    },
  );

  test('pending proposal globally blocks resend without mutation', () async {
    final streamer = _RecordingStreamer();
    final blocked = _conversation('blocked', model: 'text-model').copyWith(
      pendingMemoryProposal: PendingMemoryProposal(
        toolCallId: 'call',
        assistantMessageId: 'assistant',
        selectedAgentId: 'agent',
        allowedTools: const {'update_memory_file'},
        fileName: 'user.md',
        proposedContent: 'new',
        diff: '+new',
        confirmationToken: 'token',
        version: 'version',
        createdAt: DateTime(2026),
      ),
    );
    final target = _conversation('target', model: 'text-model', newer: true);
    final container = await bootstrap([blocked, target], streamer);

    await container
        .read(chatControllerProvider.notifier)
        .sendAgain('target', 'original-user');

    expect(
      container
          .read(chatControllerProvider)
          .requireValue
          .conversationById('target')!
          .messages,
      hasLength(3),
    );
    expect(streamer.histories, isEmpty);
    expect(
      container.read(chatControllerProvider).requireValue.errorMessage,
      isNotNull,
    );
  });

  test('in-flight request globally blocks resend', () async {
    final streamer = _ControlledStreamer();
    final container = await bootstrap([
      _conversation('target', model: 'text-model'),
    ], streamer);
    final controller = container.read(chatControllerProvider.notifier);
    final first = controller.sendAgain('target', 'original-user');
    await streamer.started.future;

    await controller.sendAgain('target', 'following-user');

    expect(
      container
          .read(chatControllerProvider)
          .requireValue
          .conversationById('target')!
          .messages,
      hasLength(5),
    );
    controller.cancel();
    await first;
  });

  test(
    'simultaneous cross-conversation resends admit only one mutation',
    () async {
      final streamer = _ControlledStreamer();
      final container = await bootstrap([
        _conversation('first', model: 'text-model', newer: true),
        _conversation('second', model: 'text-model'),
      ], streamer);
      final controller = container.read(chatControllerProvider.notifier);

      final first = controller.sendAgain('first', 'original-user');
      final second = controller.sendAgain('second', 'original-user');
      await streamer.started.future;
      await second;

      final state = container.read(chatControllerProvider).requireValue;
      expect(state.conversationById('first')!.messages, hasLength(5));
      expect(state.conversationById('second')!.messages, hasLength(3));
      controller.cancel();
      await first;
      expect(
        container
            .read(chatControllerProvider)
            .requireValue
            .conversationById('first')!
            .isStreaming,
        isFalse,
      );
    },
  );
}

Conversation _conversation(
  String id, {
  required String model,
  bool newer = false,
}) {
  final time = DateTime(2026, 1, newer ? 2 : 1);
  return Conversation(
    id: id,
    title: id,
    modelId: model,
    createdAt: time,
    updatedAt: time,
    messages: [
      ChatMessage(
        id: 'original-user',
        role: ChatRole.user,
        content: 'send exactly this',
        createdAt: time,
        attachments: [
          ChatAttachment(
            name: 'image.png',
            mimeType: 'image/png',
            dataBase64: base64Encode([1]),
          ),
          ChatAttachment(
            name: 'notes.txt',
            mimeType: 'text/plain',
            dataBase64: base64Encode(utf8.encode('note')),
          ),
        ],
      ),
      ChatMessage(
        id: 'following-assistant',
        role: ChatRole.assistant,
        content: 'keep me',
        createdAt: time,
      ),
      ChatMessage(
        id: 'following-user',
        role: ChatRole.user,
        content: 'also keep me',
        createdAt: time,
      ),
    ],
  );
}

class _EmptyAgentsController extends AgentsController {
  @override
  Future<AgentCatalog> build() async =>
      const AgentCatalog(agents: [], issues: [], selectedId: null);
}

class _RecordingStreamer implements ChatCompletionStreamer {
  final models = <String>[];
  final histories = <List<ChatMessage>>[];
  var persistedBeforeStart = false;

  @override
  Stream<ChatStreamEvent> streamCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
    List<ChatToolDefinition> tools = const [],
  }) {
    models.add(model);
    histories.add(messages);
    final stored = ConversationStore().loadAll().firstWhere(
      (conversation) => conversation.id == 'target',
    );
    persistedBeforeStart =
        stored.messages.length == 5 &&
        stored.messages.last.status == ChatMessageStatus.pending;
    return Stream.fromIterable(const [
      ChatStreamEvent(delta: 'done'),
      ChatStreamEvent(isTerminal: true, finishReason: 'stop'),
    ]);
  }
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
