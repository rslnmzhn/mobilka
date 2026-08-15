import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../agents/application/agents_controller.dart';
import '../../memory/application/memory_chat_tool_runtime.dart';
import '../../memory/application/update_memory_file_service.dart';
import '../../models/application/models_controller.dart';
import '../data/chat_repository.dart';
import '../data/conversation_store.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import 'chat_state.dart';
import 'chat_streaming_coordinator.dart';

export 'chat_state.dart';

part 'chat_controller.g.dart';

final chatCompletionStreamerProvider = Provider<ChatCompletionStreamer>(
  (ref) => ref.watch(chatRepositoryProvider),
);

@Riverpod(keepAlive: true)
class ChatController extends _$ChatController {
  ChatStreamingCoordinator? _streamingCoordinator;

  @override
  Future<ChatState> build() async {
    final store = ref.watch(conversationStoreProvider);
    await store.recoverInterrupted();
    final conversations = store.loadAll();
    return ChatState(
      conversations: conversations,
      activeConversationId: conversations.firstOrNull?.id,
    );
  }

  ChatStreamingCoordinator get _coordinator =>
      _streamingCoordinator ??= ChatStreamingCoordinator(
        streamer: ref.read(chatCompletionStreamerProvider),
        conversationById: (id) => state.requireValue.conversationById(id),
        persistAndPublish: _persistAndPublish,
        publishError: (message) {
          state = AsyncData(state.requireValue.copyWith(errorMessage: message));
        },
        toolRuntime: ref.read(memoryChatToolRuntimeProvider),
      );

  Future<void> createConversation(String modelId) async {
    final current = state.requireValue;
    final now = DateTime.now();
    final conversation = Conversation(
      id: now.microsecondsSinceEpoch.toString(),
      title: 'New conversation',
      modelId: modelId,
      createdAt: now,
      updatedAt: now,
      messages: const [],
    );
    await ref.read(conversationStoreProvider).save(conversation);
    state = AsyncData(
      current.copyWith(
        conversations: [conversation, ...current.conversations],
        activeConversationId: conversation.id,
        clearError: true,
      ),
    );
  }

  void dismissError() =>
      state = AsyncData(state.requireValue.copyWith(clearError: true));

  void selectConversation(String id) =>
      state = AsyncData(state.requireValue.copyWith(activeConversationId: id));

  void search(String query) =>
      state = AsyncData(state.requireValue.copyWith(query: query));

  void setShowArchived(bool value) =>
      state = AsyncData(state.requireValue.copyWith(showArchived: value));

  Future<void> rename(String id, String title) =>
      _updateConversation(id, (item) => item.copyWith(title: title.trim()));

  Future<void> archive(String id) =>
      _updateConversation(id, (item) => item.copyWith(isArchived: true));

  Future<void> restore(String id) =>
      _updateConversation(id, (item) => item.copyWith(isArchived: false));

  Future<void> delete(String id) async {
    await _coordinator.cancelAndWait(id);
    final current = state.requireValue;
    await ref.read(conversationStoreProvider).delete(id);
    final conversations = current.conversations
        .where((item) => item.id != id)
        .toList();
    final deletedActive = current.activeConversationId == id;
    state = AsyncData(
      current.copyWith(
        conversations: conversations,
        activeConversationId: deletedActive
            ? conversations.firstOrNull?.id
            : current.activeConversationId,
        clearActiveConversation: deletedActive && conversations.isEmpty,
      ),
    );
  }

  Future<void> send(String content) async {
    final text = content.trim();
    if (text.isEmpty || state.requireValue.hasInFlightRequest) return;
    final conversation = await _ensureConversation();
    if (conversation == null) return;
    final request = await _prepareNewRequest(conversation, text);
    await _coordinator.run(request);
  }

  Future<void> retryInterrupted(String conversationId) async {
    final current = state.requireValue;
    if (current.hasInFlightRequest) return;
    final conversation = current.conversationById(conversationId);
    if (conversation == null) return;
    final policy = await _selectedToolPolicy();
    final retry = prepareInterruptedRetry(
      conversation,
      DateTime.now(),
      selectedAgentId: policy.agentId,
      allowedTools: policy.allowedTools,
    );
    if (retry == null) return;
    await _persistAndPublish(retry.conversation, clearError: true);
    await _coordinator.run(retry.request);
  }

  Future<void> confirmPendingMemoryProposal() async {
    final conversation = state.requireValue.activeConversation;
    final proposal = conversation?.pendingMemoryProposal;
    if (conversation == null || proposal == null) return;
    final conversationId = conversation.id;
    final toolCallId = proposal.toolCallId;
    try {
      final updates = ref.read(updateMemoryFileProvider);
      if (updates == null) throw StateError('Memory storage is not configured');
      await ref
          .read(memoryChatToolRuntimeProvider)
          .revalidateMemoryProposal(proposal);
      final result = await updates.applyPersisted(
        fileName: proposal.fileName,
        proposedContent: proposal.proposedContent,
        confirmationToken: proposal.confirmationToken,
        version: proposal.version,
      );
      await _continueAfterMemoryDecision(
        conversationId,
        toolCallId,
        jsonEncode({
          'ok': true,
          'file_name': result.fileName,
          'previous_version': result.previousVersion,
          'version': result.version,
        }),
      );
    } on Object {
      state = AsyncData(
        state.requireValue.copyWith(
          errorMessage: 'chat.memoryConfirmError'.tr(),
        ),
      );
    }
  }

  Future<void> rejectPendingMemoryProposal() async {
    final conversation = state.requireValue.activeConversation;
    final proposal = conversation?.pendingMemoryProposal;
    if (conversation == null || proposal == null) return;
    await _continueAfterMemoryDecision(
      conversation.id,
      proposal.toolCallId,
      jsonEncode({'ok': false, 'rejected': true, 'reason': 'User rejected'}),
    );
  }

  Future<void> _continueAfterMemoryDecision(
    String conversationId,
    String toolCallId,
    String result,
  ) async {
    final conversation = state.requireValue.conversationById(conversationId);
    final proposal = conversation?.pendingMemoryProposal;
    if (conversation == null || proposal?.toolCallId != toolCallId) return;
    await _coordinator.continueAfterMemoryDecision(
      conversation: conversation,
      proposal: proposal!,
      toolResult: result,
    );
  }

  void cancel() {
    final id = state.requireValue.activeConversationId;
    if (id != null) _coordinator.cancel(id);
  }

  Future<Conversation?> _ensureConversation() async {
    final current = state.requireValue;
    if (current.activeConversation != null) return current.activeConversation;
    final model = ref.read(modelsControllerProvider).value?.selectedModelId;
    if (model == null) {
      state = AsyncData(current.copyWith(errorMessage: 'Select a model first'));
      return null;
    }
    await createConversation(model);
    return state.requireValue.activeConversation;
  }

  Future<ChatStreamRequest> _prepareNewRequest(
    Conversation conversation,
    String text,
  ) async {
    final policy = await _selectedToolPolicy();
    final now = DateTime.now();
    final requestId = '${now.microsecondsSinceEpoch}-user';
    final assistantId = '${now.microsecondsSinceEpoch}-assistant';
    final updated = conversation.copyWith(
      title: conversation.messages.isEmpty ? _titleFrom(text) : null,
      updatedAt: now,
      pendingRequestMessageId: requestId,
      messages: [
        ...conversation.messages,
        ChatMessage(
          id: requestId,
          role: ChatRole.user,
          content: text,
          createdAt: now,
        ),
        ChatMessage(
          id: assistantId,
          role: ChatRole.assistant,
          content: '',
          createdAt: now,
          status: ChatMessageStatus.pending,
        ),
      ],
    );
    await _persistAndPublish(updated, clearError: true);
    return buildChatStreamRequest(
      updated,
      requestId,
      assistantId,
      selectedAgentId: policy.agentId,
      allowedTools: policy.allowedTools,
    );
  }

  Future<({String? agentId, Set<String> allowedTools})>
  _selectedToolPolicy() async {
    final selected = (await ref.read(agentsControllerProvider.future)).selected;
    return (
      agentId: selected?.definition.id,
      allowedTools: Set.unmodifiable(
        selected?.definition.tools ?? const <String>[],
      ),
    );
  }

  Future<void> _updateConversation(
    String id,
    Conversation Function(Conversation) update,
  ) async {
    final existing = state.requireValue.conversationById(id);
    if (existing == null) return;
    await _persistAndPublish(
      update(existing).copyWith(updatedAt: DateTime.now()),
    );
  }

  Future<void> _persistAndPublish(
    Conversation conversation, {
    bool clearError = false,
  }) async {
    await ref.read(conversationStoreProvider).save(conversation);
    final current = state.requireValue;
    final conversations =
        current.conversations
            .map((item) => item.id == conversation.id ? conversation : item)
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    state = AsyncData(
      current.copyWith(
        conversations: conversations,
        activeConversationId: current.activeConversationId ?? conversation.id,
        clearError: clearError,
      ),
    );
  }

  static String _titleFrom(String text) =>
      text.length <= 42 ? text : '${text.substring(0, 39)}...';
}
