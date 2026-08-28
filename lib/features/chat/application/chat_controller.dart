import 'package:easy_localization/easy_localization.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/logging/app_logger.dart';
import '../../agents/application/agents_controller.dart';
import '../../memory/application/update_memory_file_service.dart';
import '../../models/application/models_controller.dart';
import '../../models/domain/model_capabilities.dart';
import '../../../features/memory/application/instant_memory_writer.dart';
import '../../../features/memory/application/persona_registry.dart';
import '../../../features/memory/application/workspace_paths.dart';
import '../../../features/memory/data/memory_repository.dart';
import 'background_task_bridge.dart';
import 'automatic_title_coordinator.dart';
import 'conversation_mutation.dart';
import 'chat_tool_runtime_registry.dart';
import '../data/chat_repository.dart';
import '../data/conversation_store.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import 'chat_state.dart';
import 'chat_memory_decision_service.dart';
import 'chat_lifecycle_service.dart';
import 'chat_streaming_coordinator.dart';
import 'pending_workspace_binding_store.dart';

export 'chat_state.dart';

part 'chat_controller.g.dart';

final chatCompletionStreamerProvider = Provider<ChatCompletionStreamer>(
  (ref) => ref.watch(chatRepositoryProvider),
);

@Riverpod(keepAlive: true)
class ChatController extends _$ChatController {
  late final ChatLifecycleService _lifecycle;
  late final AutomaticTitleCoordinator _automaticTitles;

  @override
  Future<ChatState> build() async {
    final store = ref.watch(conversationStoreProvider);
    await store.recoverInterrupted();
    final conversations = store.loadAll();
    _automaticTitles = AutomaticTitleCoordinator(
      conversationById: (id) => state.valueOrNull?.conversationById(id),
      persist: _saveAndPublishAuthoritative,
    );
    _lifecycle = ChatLifecycleService(
      persistMutation: _persistMutation,
      generationFactory: _buildLifecycleGeneration,
    );
    ref.onDispose(_lifecycle.dispose);
    return ChatState(
      conversations: conversations,
      activeConversationId: conversations.firstOrNull?.id,
    );
  }

  ChatLifecycleGeneration _buildLifecycleGeneration(
    int revision,
    PendingWorkspaceBindingStore workspaceBindings,
    PersistConversationMutation persistMutation,
  ) {
    final runtime = ref.read(chatToolRuntimeRegistryProvider);
    return ChatLifecycleGeneration(
      memoryRuntime: runtime,
      memoryUpdates: ref.read(updateMemoryFileProvider),
      coordinator: ChatStreamingCoordinator(
        streamer: ref.read(chatCompletionStreamerProvider),
        conversationById: (id) => state.requireValue.conversationById(id),
        persistMutation: persistMutation,
        publishError: (message) {
          state = AsyncData(
            state.requireValue.copyWith(
              errorMessage: message == 'backgroundUnavailable'
                  ? message.tr()
                  : message,
            ),
          );
        },
        toolRuntime: runtime,
        backgroundTasks: ref.read(backgroundTaskBridgeProvider),
        instantMemoryWriter: ref.read(instantMemoryWriterProvider),
        personaRegistry: ref.read(personaRegistryAdapterProvider),
        logger: ref.read(appLoggerProvider),
        workspaceBindings: workspaceBindings,
        onFinalSuccess: _startAutomaticTitle,
      ),
    );
  }

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
      titleState: ConversationTitleState.pendingAutomatic,
      sessionKey: WorkspaceStore.sessionKey(
        createdAt: now,
        title: 'New conversation',
        conversationId: now.microsecondsSinceEpoch.toString(),
      ),
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

  /// Applies a model choice globally and to the active conversation.
  ///
  /// Requests are built from `conversation.modelId`, so switching models from
  /// the chat picker must persist the change on the conversation itself;
  /// otherwise the previous model keeps serving this chat.
  Future<void> applyModel(String modelId) async {
    await ref.read(modelsControllerProvider.notifier).select(modelId);
    final current = state.requireValue;
    final conversation = current.activeConversation;
    if (conversation == null || conversation.modelId == modelId) return;
    await _updateConversation(
      conversation.id,
      (item) => item.copyWith(modelId: modelId),
    );
  }

  void dismissError() =>
      state = AsyncData(state.requireValue.copyWith(clearError: true));

  /// Persists the newest snapshot of the active conversation.
  ///
  /// Lifecycle safety net (roadmap item 47): streaming already persists every
  /// delta, but the final batch can be lost if the process dies between the
  /// last event and the next save — this flush makes pause/hidden durable.
  Future<void> flushActiveConversation() async {
    final conversation = state.valueOrNull?.activeConversation;
    if (conversation == null) return;
    await _persistMutation(conversation.id, (latest) => latest);
  }

  void selectConversation(String id) =>
      state = AsyncData(state.requireValue.copyWith(activeConversationId: id));

  void search(String query) =>
      state = AsyncData(state.requireValue.copyWith(query: query));

  void setShowArchived(bool value) =>
      state = AsyncData(state.requireValue.copyWith(showArchived: value));

  Future<void> rename(String id, String title) => _updateConversation(
    id,
    (item) => item.copyWith(
      title: title.trim(),
      titleState: ConversationTitleState.manual,
    ),
  );

  Future<void> archive(String id) =>
      _updateConversation(id, (item) => item.copyWith(isArchived: true));

  Future<void> restore(String id) =>
      _updateConversation(id, (item) => item.copyWith(isArchived: false));

  Future<void> delete(String id) async {
    await _lifecycle.cancelAndWait(id);
    await _automaticTitles.serialize(id, () async {
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
    });
  }

  Future<void> send(
    String content, {
    List<ChatAttachment> attachments = const [],
  }) async {
    final text = content.trim();
    if (text.isEmpty || state.requireValue.hasInFlightRequest) return;
    final conversation = await _ensureConversation();
    if (conversation == null) return;
    final revision = ref.read(memoryLocationRevisionProvider);
    _lifecycle.coordinatorForRequest(revision);
    final request = await _prepareNewRequest(conversation, text, attachments);
    await _lifecycle.run(request, locationRevision: revision);
  }

  Future<void> retryInterrupted(String conversationId) async {
    final current = state.requireValue;
    if (current.hasInFlightRequest) return;
    final conversation = current.conversationById(conversationId);
    if (conversation == null) return;
    final revision = ref.read(memoryLocationRevisionProvider);
    final coordinator = _lifecycle.coordinatorForRetry(revision);
    final policy = await _selectedToolPolicy();
    final retry = prepareInterruptedRetry(
      conversation,
      DateTime.now(),
      selectedAgentId: policy.agentId,
      allowedTools: policy.allowedTools,
      workspaceBinding: _retryWorkspaceBinding(conversation, coordinator),
    );
    if (retry == null) return;
    final retryAssistant = retry.conversation.messages.last;
    final persisted = await _persistMutation(
      conversationId,
      (latest) => latest.copyWith(
        updatedAt: retry.conversation.updatedAt,
        messages: [...latest.messages, retryAssistant],
      ),
    );
    _clearError();
    if (persisted == null) return;
    await _lifecycle.run(
      buildChatStreamRequest(
        persisted,
        retry.request.requestMessageId,
        retry.request.assistantMessageId,
        selectedAgentId: retry.request.selectedAgentId,
        allowedTools: retry.request.allowedTools,
        workspaceBinding: retry.request.workspaceBinding,
      ),
      locationRevision: revision,
    );
  }

  void cancel() {
    final id = state.requireValue.activeConversationId;
    if (id != null) _lifecycle.cancel(id);
  }

  Future<void> confirmPendingMemoryProposal() async {
    final conversation = state.requireValue.activeConversation;
    final proposal = conversation?.pendingMemoryProposal;
    if (proposal != null) {
      state = AsyncData(
        state.requireValue.copyWith(
          confirmingMemoryToolCallId: proposal.toolCallId,
          clearError: true,
        ),
      );
    }
    try {
      _applyMemoryDecisionAction(
        await _memoryDecisionService.confirm(
          conversation: conversation,
          proposal: proposal,
        ),
      );
    } finally {
      if (proposal != null &&
          state.hasValue &&
          state.requireValue.confirmingMemoryToolCallId ==
              proposal.toolCallId) {
        state = AsyncData(
          state.requireValue.copyWith(clearConfirmingMemory: true),
        );
      }
    }
  }

  Future<void> rejectPendingMemoryProposal() async {
    final conversation = state.requireValue.activeConversation;
    final proposal = conversation?.pendingMemoryProposal;
    if (conversation == null || proposal == null) return;
    _applyMemoryDecisionAction(
      await _memoryDecisionService.reject(
        conversation: conversation,
        proposal: proposal,
      ),
    );
  }

  ChatMemoryDecisionService get _memoryDecisionService =>
      ChatMemoryDecisionService(
        logger: ref.read(appLoggerProvider),
        servicesForDecision: (conversationId, proposal) =>
            _lifecycle.servicesForDecision(
              conversationId,
              proposal,
              locationRevision: ref.read(memoryLocationRevisionProvider),
            ),
        conversationById: (id) => state.requireValue.conversationById(id),
        completeDecision: _lifecycle.completeDecision,
        refreshPersonas: () =>
            ref.read(personaRegistryStateProvider.notifier).refresh(),
      );

  void _applyMemoryDecisionAction(ChatMemoryDecisionAction action) {
    if (action.errorMessage == null) return;
    final current = state.requireValue;
    state = AsyncData(current.copyWith(errorMessage: action.errorMessage));
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
    List<ChatAttachment> rawAttachments,
  ) async {
    final policy = await _selectedToolPolicy();
    final now = DateTime.now();
    final requestId = '${now.microsecondsSinceEpoch}-user';
    final assistantId = '${now.microsecondsSinceEpoch}-assistant';
    final capabilities = ModelCapabilityResolver.resolve(conversation.modelId);
    final attachments = filterAttachmentsForModel(
      rawAttachments,
      visionSupported: capabilities.vision,
    );
    if (rawAttachments.isNotEmpty &&
        attachments.length < rawAttachments.length) {
      state = AsyncData(
        state.requireValue.copyWith(
          errorMessage: 'chat.visionUnsupported'.tr(),
        ),
      );
    }
    final updated = await _automaticTitles.mutate(
      conversation.id,
      (latest) => latest.copyWith(
        title: latest.messages.isEmpty ? _titleFrom(text) : null,
        updatedAt: now,
        pendingRequestMessageId: requestId,
        messages: [
          ...latest.messages,
          ChatMessage(
            id: requestId,
            role: ChatRole.user,
            content: text,
            createdAt: now,
            attachments: List.unmodifiable(attachments),
          ),
          ChatMessage(
            id: assistantId,
            role: ChatRole.assistant,
            content: '',
            createdAt: now,
            status: ChatMessageStatus.pending,
          ),
        ],
      ),
    );
    if (updated == null) throw StateError('Conversation was deleted');
    _clearError();
    return buildChatStreamRequest(
      updated,
      requestId,
      assistantId,
      selectedAgentId: policy.agentId,
      allowedTools: policy.allowedTools,
      workspaceBinding: _captureWorkspaceBinding(),
    );
  }

  WorkspaceBinding? _captureWorkspaceBinding() => WorkspaceStore(
    repository: ref.read(memoryRepositoryProvider),
  ).captureBinding();

  WorkspaceBinding? _retryWorkspaceBinding(
    Conversation conversation,
    ChatStreamingCoordinator coordinator,
  ) {
    final requestMessageId = conversation.pendingRequestMessageId!;
    final retained = coordinator.retainedWorkspaceBindingForRetry(
      conversation.id,
      requestMessageId,
    );
    if (retained != null) return retained;
    final requestIndex = conversation.messages.indexWhere(
      (message) => message.id == requestMessageId,
    );
    final followedMemoryDecision = conversation.messages
        .skip(
          requestIndex < 0 ? conversation.messages.length : requestIndex + 1,
        )
        .any(
          (message) => message.toolCalls.any(
            (call) =>
                call.name == 'update_memory_file' ||
                call.name == 'save_persona' ||
                call.name == 'delete_persona',
          ),
        );
    return followedMemoryDecision ? null : _captureWorkspaceBinding();
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
  ) => _automaticTitles.mutate(
    id,
    (latest) => update(latest).copyWith(updatedAt: DateTime.now()),
  );

  Future<Conversation?> _persistMutation(
    String conversationId,
    ConversationMutation mutation,
  ) => _automaticTitles.mutate(conversationId, mutation);

  Future<void> _saveAndPublishAuthoritative(Conversation conversation) async {
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
      ),
    );
  }

  void _clearError() {
    final current = state.requireValue;
    state = AsyncData(current.copyWith(clearError: true));
  }

  static String _titleFrom(String text) =>
      text.length <= 42 ? text : '${text.substring(0, 39)}...';

  void _startAutomaticTitle(ChatStreamRequest request, String assistantText) {
    Future<void>(() async {
      try {
        final claimed = await _automaticTitles.claim(request.conversationId);
        if (claimed == null) return;
        final firstUser = claimed.messages
            .where((message) => message.role == ChatRole.user)
            .firstOrNull;
        if (firstUser == null) return;
        final generated = await ref
            .read(chatRepositoryProvider)
            .createAutomaticTitle(
              model: request.modelId,
              firstUserText: firstUser.content,
              assistantText: assistantText,
            );
        await _automaticTitles.complete(request.conversationId, generated);
      } on Object {
        return;
      }
    });
  }
}
