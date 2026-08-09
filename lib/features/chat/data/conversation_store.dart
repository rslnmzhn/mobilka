import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/storage/app_boxes.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';

part 'conversation_store.g.dart';

@Riverpod(keepAlive: true)
ConversationStore conversationStore(Ref ref) => ConversationStore();

class ConversationStore {
  List<Conversation> loadAll() {
    return conversationsBox.values
        .whereType<Map>()
        .map(Conversation.fromJson)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<void> save(Conversation conversation) =>
      conversationsBox.put(conversation.id, conversation.toJson());

  Future<void> delete(String id) => conversationsBox.delete(id);

  Future<void> recoverInterrupted() async {
    for (final conversation in loadAll()) {
      var changed = false;
      final messages = conversation.messages.map((message) {
        if (message.status == ChatMessageStatus.pending ||
            message.status == ChatMessageStatus.streaming) {
          changed = true;
          return message.copyWith(status: ChatMessageStatus.interrupted);
        }
        return message;
      }).toList();
      if (changed) {
        await save(conversation.copyWith(messages: messages));
      }
    }
  }
}
