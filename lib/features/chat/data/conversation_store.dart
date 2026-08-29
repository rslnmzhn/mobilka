import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/storage/app_boxes.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import '../domain/pending_tool_proposal.dart';
import '../domain/pending_skill_proposal.dart';

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
      final recovered = _recoverExecutingProposal(conversation);
      if (recovered != null) {
        await save(recovered);
        continue;
      }
      final messages = _interruptMessages(conversation.messages);
      if (!_sameMessages(messages, conversation.messages)) {
        await save(conversation.copyWith(messages: messages));
      }
    }
  }

  Conversation? _recoverExecutingProposal(Conversation conversation) {
    final now = DateTime.now();
    final messages = _interruptMessages(conversation.messages);
    if (conversation.pendingSkillProposal?.state ==
        PendingSkillProposalState.executing) {
      return conversation.copyWith(
        clearPendingSkillProposal: true,
        clearPendingRequest: true,
        updatedAt: now,
        messages: [
          ...messages,
          ChatMessage(
            id: '${now.microsecondsSinceEpoch}-skill-indeterminate',
            role: ChatRole.system,
            content: 'skill_mutation_indeterminate',
            createdAt: now,
          ),
        ],
      );
    }
    final toolProposal = conversation.pendingToolProposal;
    if (toolProposal != null &&
        toolProposal.state == PendingToolProposalState.executing) {
      return conversation.copyWith(
        updatedAt: now,
        clearPendingRequest: true,
        clearPendingToolProposal: true,
        messages: [
          ...messages,
          ChatMessage(
            id: '${now.microsecondsSinceEpoch}-tool-indeterminate',
            role: ChatRole.tool,
            content: '{"ok":false,"error_code":"execution_indeterminate"}',
            createdAt: now,
            toolCallId: toolProposal.call.id,
          ),
        ],
      );
    }
    return null;
  }

  List<ChatMessage> _interruptMessages(List<ChatMessage> messages) =>
      messages.map((message) => _interruptMessage(message)).toList();

  ChatMessage _interruptMessage(ChatMessage message) {
    if (message.status == ChatMessageStatus.pending ||
        message.status == ChatMessageStatus.streaming) {
      return message.copyWith(status: ChatMessageStatus.interrupted);
    }
    return message;
  }

  bool _sameMessages(List<ChatMessage> first, List<ChatMessage> second) {
    for (var index = 0; index < first.length; index++) {
      if (!identical(first[index], second[index])) return false;
    }
    return true;
  }
}
