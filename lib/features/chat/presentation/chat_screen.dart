import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../artifacts/presentation/artifacts_bottom_sheet.dart';
import '../../models/application/models_controller.dart';
import '../../models/domain/model_capabilities.dart';
import '../application/chat_controller.dart';
import '../domain/chat_message.dart';
import '../domain/tool_execution.dart';
import 'chat_composer.dart';
import 'chat_edge_swipe_access.dart';
import 'chat_header.dart';
import 'chat_message_widgets.dart';
import 'conversations_drawer.dart';

export 'chat_composer.dart' show ChatComposer;
export 'chat_header.dart' show ModelPickerSheet;

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final scaffoldKey = GlobalKey<ScaffoldState>();
  final composer = TextEditingController();
  final scrollController = ScrollController();

  /// Auto-follow streaming output while the user is at the bottom; a swipe
  /// up pauses it until they return (roadmap: chat UX).
  var _pinnedToBottom = true;
  var _presentingRoute = false;

  @override
  void initState() {
    super.initState();
    // Jump to the newest message once the first frame is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is UserScrollNotification) {
      final goingUp = notification.direction == ScrollDirection.reverse;
      if (goingUp && _pinnedToBottom) {
        setState(() => _pinnedToBottom = false);
      }
    } else if (notification is ScrollUpdateNotification) {
      final metrics = notification.metrics;
      final nearBottom =
          metrics.pixels >= metrics.maxScrollExtent - 80 &&
          metrics.axis == Axis.vertical;
      if (nearBottom && !_pinnedToBottom) {
        setState(() => _pinnedToBottom = true);
      }
    }
    return false;
  }

  void _scrollToBottom() {
    if (!scrollController.hasClients || !_pinnedToBottom) return;
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
  }

  Future<String?> _pickModel(ModelsState models) async {
    if (!_canPresentRoute()) return null;
    _presentingRoute = true;
    try {
      return await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => ModelPickerSheet(models: models),
      );
    } finally {
      _presentingRoute = false;
    }
  }

  Future<void> _selectModel(ModelsState models) async {
    final modelId = await _pickModel(models);
    if (modelId == null) return;
    // Applies globally and to the active conversation so this chat actually
    // switches models.
    await ref.read(chatControllerProvider.notifier).applyModel(modelId);
  }

  Future<void> _showArtifacts() async {
    if (!_canPresentRoute()) return;
    _presentingRoute = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => Consumer(
          builder: (context, ref, _) => ArtifactsBottomSheet(
            conversation: ref
                .watch(chatControllerProvider)
                .value
                ?.activeConversation,
          ),
        ),
      );
    } finally {
      _presentingRoute = false;
    }
  }

  bool _canPresentRoute() =>
      !_presentingRoute &&
      !(scaffoldKey.currentState?.isDrawerOpen ?? false) &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  void _showHistory() {
    if (!_canPresentRoute()) return;
    scaffoldKey.currentState?.openDrawer();
  }

  Future<void> _createConversation(ModelsState? models) async {
    if (models == null) return;
    var modelId = models.selectedModelId;
    if (!models.visibleModels.any((model) => model.id == modelId)) {
      modelId = await _pickModel(models);
      if (modelId == null) return;
      await ref.read(modelsControllerProvider.notifier).select(modelId);
    }
    final selectedModelId = modelId;
    if (selectedModelId == null) return;
    await ref
        .read(chatControllerProvider.notifier)
        .createConversation(selectedModelId);
  }

  @override
  void dispose() {
    composer.dispose();
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatControllerProvider);
    final models = ref.watch(modelsControllerProvider);
    // Auto-follow streaming output while pinned to the bottom.
    ref.listen<AsyncValue<ChatState>>(chatControllerProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    });
    return Scaffold(
      key: scaffoldKey,
      appBar: ChatHeaderBar(
        title:
            chat.value?.activeConversation?.title ?? 'chatNoConversation'.tr(),
        modelId:
            chat.value?.activeConversation?.modelId ??
            models.value?.selectedModelId,
        onModelPressed: models.value == null
            ? () {}
            : () => _selectModel(models.value!),
        onNewChat: models.isLoading
            ? null
            : () => _createConversation(models.value),
      ),
      drawer: ConversationsDrawer(chat: chat),
      body: Builder(
        builder: (_) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyH, control: true):
                _showHistory,
            const SingleActivator(LogicalKeyboardKey.keyA, control: true):
                _showArtifacts,
          },
          child: Focus(
            autofocus: true,
            child: Semantics(
              customSemanticsActions: {
                CustomSemanticsAction(label: 'chat.search'.tr()): _showHistory,
                CustomSemanticsAction(label: 'artifacts.open'.tr()):
                    _showArtifacts,
              },
              child: ChatEdgeSwipeAccess(
                canPresent: _canPresentRoute,
                onHistory: _showHistory,
                onArtifacts: _showArtifacts,
                child: chat.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => Center(child: Text(error.toString())),
                  data: (state) {
                    final conversation = state.activeConversation;
                    final toolExecutions = projectToolExecutions(conversation);
                    final messages = conversation?.messages
                        .where((message) => message.role != ChatRole.tool)
                        .toList();
                    return Column(
                      children: [
                        if (state.errorMessage != null)
                          MaterialBanner(
                            content: Text(state.errorMessage!),
                            actions: [
                              TextButton(
                                onPressed: ref
                                    .read(chatControllerProvider.notifier)
                                    .dismissError,
                                child: Text('common.close'.tr()),
                              ),
                            ],
                          ),
                        Expanded(
                          child:
                              conversation == null ||
                                  conversation.messages.isEmpty
                              ? EmptyChat(
                                  onCreate: () =>
                                      _createConversation(models.value),
                                )
                              : Center(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 920,
                                    ),
                                    child: NotificationListener<ScrollNotification>(
                                      onNotification: _onScrollNotification,
                                      child: ListView.builder(
                                        controller: scrollController,
                                        padding: const EdgeInsets.fromLTRB(
                                          20,
                                          20,
                                          20,
                                          12,
                                        ),
                                        itemCount: messages!.length,
                                        itemBuilder: (context, index) =>
                                            MessageCard(
                                              key: ValueKey(messages[index].id),
                                              message: messages[index],
                                              onSendAgain:
                                                  messages[index].role ==
                                                      ChatRole.user
                                                  ? () => ref
                                                        .read(
                                                          chatControllerProvider
                                                              .notifier,
                                                        )
                                                        .sendAgain(
                                                          conversation.id,
                                                          messages[index].id,
                                                        )
                                                  : null,
                                              toolExecutions: toolExecutions
                                                  .where(
                                                    (execution) =>
                                                        execution
                                                            .assistantMessageId ==
                                                        messages[index].id,
                                                  )
                                                  .toList(growable: false),
                                            ),
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                        if (conversation?.pendingMemoryProposal
                            case final proposal?)
                          PendingMemoryProposalCard(
                            fileName: proposal.fileName,
                            diff: proposal.diff,
                            isBusy:
                                state.confirmingMemoryToolCallId ==
                                proposal.toolCallId,
                            onConfirm: ref
                                .read(chatControllerProvider.notifier)
                                .confirmPendingMemoryProposal,
                            onReject: ref
                                .read(chatControllerProvider.notifier)
                                .rejectPendingMemoryProposal,
                          ),
                        ChatComposer(
                          controller: composer,
                          isStreaming: state.isStreaming,
                          canSend:
                              models.value?.selectedModelId != null ||
                              conversation != null,
                          visionSupported: ModelCapabilityResolver.resolve(
                            conversation?.modelId ??
                                models.value?.selectedModelId ??
                                '',
                          ).vision,
                          visionNote: 'chat.visionUnsupported'.tr(),
                          onCancel: ref
                              .read(chatControllerProvider.notifier)
                              .cancel,
                          onSend: (text, attachments) {
                            composer.clear();
                            _pinnedToBottom = true;
                            WidgetsBinding.instance.addPostFrameCallback(
                              (_) => _scrollToBottom(),
                            );
                            ref
                                .read(chatControllerProvider.notifier)
                                .send(text, attachments: attachments);
                          },
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
