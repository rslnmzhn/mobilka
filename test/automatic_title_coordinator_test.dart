import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/automatic_title_coordinator.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';

void main() {
  Conversation conversation(
    ConversationTitleState state, {
    String title = 'fallback',
  }) {
    final now = DateTime.utc(2026);
    return Conversation(
      id: 'conversation',
      title: title,
      modelId: 'model',
      createdAt: now,
      updatedAt: now,
      messages: const [],
      titleState: state,
      sessionKey: 'stable',
    );
  }

  test(
    'claim merges latest state and duplicate callback claims once',
    () async {
      var current = conversation(ConversationTitleState.pendingAutomatic);
      var saves = 0;
      final coordinator = AutomaticTitleCoordinator(
        conversationById: (_) => current,
        persist: (value) async {
          saves++;
          current = value;
        },
      );

      final claims = await Future.wait([
        coordinator.claim('conversation'),
        coordinator.claim('conversation'),
      ]);

      expect(claims.whereType<Conversation>(), hasLength(1));
      expect(saves, 1);
      expect(current.sessionKey, 'stable');
    },
  );

  test(
    'delayed title completion preserves next request and streaming snapshot',
    () async {
      var current = conversation(ConversationTitleState.pendingAutomatic);
      final coordinator = AutomaticTitleCoordinator(
        conversationById: (_) => current,
        persist: (value) async => current = value,
      );
      await coordinator.claim('conversation');
      final completionGate = Completer<void>();
      final completion = Future<void>(() async {
        await completionGate.future;
        await coordinator.complete('conversation', 'Generated title');
      });
      final now = DateTime.utc(2026, 1, 2);
      await coordinator.mutate(
        'conversation',
        (latest) => latest.copyWith(
          pendingRequestMessageId: 'user-2',
          updatedAt: now,
          messages: [
            ...latest.messages,
            ChatMessage(
              id: 'user-2',
              role: ChatRole.user,
              content: 'Next',
              createdAt: now,
            ),
            ChatMessage(
              id: 'assistant-2',
              role: ChatRole.assistant,
              content: '',
              createdAt: now,
              status: ChatMessageStatus.pending,
            ),
          ],
        ),
      );
      await coordinator.mutate(
        'conversation',
        (latest) => latest.copyWith(
          messages: latest.messages
              .map(
                (message) => message.id == 'assistant-2'
                    ? message.copyWith(
                        content: 'Partial',
                        status: ChatMessageStatus.streaming,
                      )
                    : message,
              )
              .toList(),
        ),
      );

      completionGate.complete();
      await completion;

      expect(current.title, 'Generated title');
      expect(current.titleState, ConversationTitleState.generated);
      expect(current.pendingRequestMessageId, 'user-2');
      expect(current.messages.map((message) => message.id), [
        'user-2',
        'assistant-2',
      ]);
      expect(current.messages.last.content, 'Partial');
      expect(current.messages.last.status, ChatMessageStatus.streaming);
      expect(current.sessionKey, 'stable');
    },
  );

  test('manual rename and deletion win before claim or completion', () async {
    Conversation? current = conversation(
      ConversationTitleState.manual,
      title: 'Mine',
    );
    final coordinator = AutomaticTitleCoordinator(
      conversationById: (_) => current,
      persist: (value) async => current = value,
    );
    expect(await coordinator.claim('conversation'), isNull);

    current = conversation(ConversationTitleState.fallback);
    current = null;
    await coordinator.complete('conversation', 'Generated');
    expect(current, isNull);
  });

  test(
    'manual rename during delayed claim is preserved by serialized mutation',
    () async {
      var current = conversation(ConversationTitleState.pendingAutomatic);
      final entered = Completer<void>();
      final release = Completer<void>();
      final coordinator = AutomaticTitleCoordinator(
        conversationById: (_) => current,
        persist: (value) async {
          if (!entered.isCompleted) {
            entered.complete();
            await release.future;
          }
          current = value;
        },
      );

      final claim = coordinator.claim('conversation');
      await entered.future;
      final rename = coordinator.mutate(
        'conversation',
        (latest) => latest.copyWith(
          title: 'Mine',
          titleState: ConversationTitleState.manual,
        ),
      );
      release.complete();
      await claim;
      await rename;
      await coordinator.complete('conversation', 'Generated');
      expect(current.title, 'Mine');
    },
  );

  test(
    'queued stale stream delta cannot overwrite newer authoritative fields',
    () async {
      var current = conversation(ConversationTitleState.manual, title: 'Mine');
      final coordinator = AutomaticTitleCoordinator(
        conversationById: (_) => current,
        persist: (value) async => current = value,
      );
      final now = DateTime.utc(2026, 2);
      await coordinator.mutate(
        'conversation',
        (latest) => latest.copyWith(
          modelId: 'model-b',
          isArchived: true,
          pendingRequestMessageId: 'user-2',
          messages: [
            ChatMessage(
              id: 'user-2',
              role: ChatRole.user,
              content: 'Next',
              createdAt: now,
            ),
            ChatMessage(
              id: 'assistant-2',
              role: ChatRole.assistant,
              content: '',
              createdAt: now,
              status: ChatMessageStatus.pending,
            ),
          ],
        ),
      );

      final stale = await coordinator.mutate('conversation', (latest) {
        if (latest.pendingRequestMessageId != 'user-1') return null;
        return latest.copyWith(messages: const []);
      });

      expect(stale, isNull);
      expect(current.modelId, 'model-b');
      expect(current.isArchived, isTrue);
      expect(current.title, 'Mine');
      expect(current.pendingRequestMessageId, 'user-2');
      expect(current.messages, hasLength(2));
      expect(current.sessionKey, 'stable');
    },
  );

  test(
    'queued delete prevents later mutation from resurrecting conversation',
    () async {
      Conversation? current = conversation(ConversationTitleState.fallback);
      final coordinator = AutomaticTitleCoordinator(
        conversationById: (_) => current,
        persist: (value) async => current = value,
      );

      await coordinator.serialize('conversation', () async => current = null);
      final result = await coordinator.mutate(
        'conversation',
        (latest) => latest.copyWith(modelId: 'resurrected'),
      );

      expect(result, isNull);
      expect(current, isNull);
    },
  );
}
