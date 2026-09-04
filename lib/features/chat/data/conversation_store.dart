import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/storage/app_boxes.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import '../domain/pending_tool_proposal.dart';
import '../domain/pending_skill_proposal.dart';
import '../domain/pending_workspace_proposal.dart';

part 'conversation_store.g.dart';

@Riverpod(keepAlive: true)
ConversationStore conversationStore(Ref ref) => ConversationStore();

class ConversationStore {
  List<Conversation> loadAll() {
    final result = <Conversation>[];
    for (final value in conversationsBox.values.whereType<Map>()) {
      try {
        result.add(Conversation.fromJson(value));
      } on Object {
        // A corrupt record must not prevent unrelated conversations loading.
      }
    }
    return result..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<void> save(Conversation conversation) =>
      conversationsBox.put(conversation.id, conversation.toJson());

  Future<void> delete(String id) => conversationsBox.delete(id);

  Conversation? loadById(String id) {
    final raw = conversationsBox.get(id);
    if (raw is! Map) return null;
    try {
      final conversation = Conversation.fromJson(raw);
      return conversation.id == id ? conversation : null;
    } on Object {
      return null;
    }
  }

  Future<void> recoverInterrupted() async {
    for (final conversation in loadAll()) {
      if (conversation.invalidPendingWorkspaceProposal) {
        await save(_terminalizeInvalidWorkspaceProposal(conversation));
        continue;
      }
      if (conversation.pendingWorkspaceProposal?.status ==
          WorkspaceProposalStatus.executing) {
        // Startup reconciliation owns this request and its active context.
        continue;
      }
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

  Conversation _terminalizeInvalidWorkspaceProposal(Conversation conversation) {
    final now = DateTime.now();
    return conversation.copyWith(
      updatedAt: now,
      clearPendingRequest: true,
      clearPendingWorkspaceProposal: true,
      messages: [
        ..._interruptMessages(conversation.messages),
        ChatMessage(
          id: '${now.microsecondsSinceEpoch}-workspace-recovery-invalid',
          role: ChatRole.tool,
          content: '{"ok":false,"error_code":"workspace_recovery_invalid"}',
          createdAt: now,
          toolCallId: conversation.invalidWorkspaceToolCallId,
          toolCallIndex: conversation.invalidWorkspaceToolCallIndex,
        ),
      ],
    );
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
