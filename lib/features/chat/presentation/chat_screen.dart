import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/workbench_widgets.dart';
import '../../artifacts/presentation/artifacts_bottom_sheet.dart';
import '../../models/application/models_controller.dart';
import '../../models/domain/model_capabilities.dart';
import '../application/chat_controller.dart';
import '../domain/chat_message.dart';
import '../domain/tool_execution.dart';
import 'chat_composer.dart';
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
  final composer = TextEditingController();
  final scrollController = ScrollController();

  /// Auto-follow streaming output while the user is at the bottom; a swipe
  /// up pauses it until they return (roadmap: chat UX).
  var _pinnedToBottom = true;

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

  Future<String?> _pickModel(ModelsState models) =>
      showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => ModelPickerSheet(models: models),
      );

  Future<void> _selectModel(ModelsState models) async {
    final modelId = await _pickModel(models);
    if (modelId == null) return;
    // Applies globally and to the active conversation so this chat actually
    // switches models.
    await ref.read(chatControllerProvider.notifier).applyModel(modelId);
  }

  Future<void> _showArtifacts() => showModalBottomSheet<void>(
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
      appBar: AppBar(
        title: WorkbenchPageTitle(
          icon: Icons.forum_outlined,
          title: 'nav.chat'.tr(),
          detail: 'MOBILKA SESSION',
        ),
        leading: Builder(
          builder: (context) => IconButton(
            onPressed: () => Scaffold.of(context).openDrawer(),
            icon: const Icon(Icons.menu),
          ),
        ),
        actions: [
          models.when(
            data: (state) {
              // The active conversation's model is what requests actually
              // use; show it instead of the global default when they differ.
              final conversationModelId =
                  chat.value?.activeConversation?.modelId;
              final shownModelId =
                  (conversationModelId != null &&
                      state.visibleModels.any(
                        (model) => model.id == conversationModelId,
                      ))
                  ? conversationModelId
                  : state.selectedModelId;
              return ModelPickerButton(
                modelId:
                    state.visibleModels.any((model) => model.id == shownModelId)
                    ? shownModelId
                    : null,
                onPressed: () => _selectModel(state),
              );
            },
            loading: () => const SizedBox.square(
              dimension: 40,
              child: Padding(
                padding: EdgeInsets.all(11),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            error: (_, _) => const SizedBox.shrink(),
          ),
          IconButton(
            tooltip: 'chat.newConversation'.tr(),
            onPressed: models.isLoading
                ? null
                : () => _createConversation(models.value),
            icon: const Icon(Icons.add_comment_outlined),
          ),
          IconButton(
            key: const Key('open-artifacts'),
            tooltip: 'artifacts.open'.tr(),
            onPressed: _showArtifacts,
            icon: const Icon(Icons.inventory_2_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      drawer: ConversationsDrawer(chat: chat),
      body: chat.when(
        loading: () => const Center(child: CircularProgressIndicator()),
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
                child: conversation == null || conversation.messages.isEmpty
                    ? EmptyChat(
                        onCreate: () => _createConversation(models.value),
                      )
                    : Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 920),
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
                              itemBuilder: (context, index) => MessageCard(
                                key: ValueKey(messages[index].id),
                                message: messages[index],
                                toolExecutions: toolExecutions
                                    .where(
                                      (execution) =>
                                          execution.assistantMessageId ==
                                          messages[index].id,
                                    )
                                    .toList(growable: false),
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
              if (conversation?.pendingMemoryProposal case final proposal?)
                PendingMemoryProposalCard(
                  fileName: proposal.fileName,
                  diff: proposal.diff,
                  isBusy:
                      state.confirmingMemoryToolCallId == proposal.toolCallId,
                  onConfirm: ref
                      .read(chatControllerProvider.notifier)
                      .confirmPendingMemoryProposal,
                  onReject: ref
                      .read(chatControllerProvider.notifier)
                      .rejectPendingMemoryProposal,
                ),
              ContextIndicator(conversation: conversation, state: state),
              ChatComposer(
                controller: composer,
                isStreaming: state.isStreaming,
                canSend:
                    models.value?.selectedModelId != null ||
                    conversation != null,
                visionSupported: ModelCapabilityResolver.resolve(
                  conversation?.modelId ?? models.value?.selectedModelId ?? '',
                ).vision,
                visionNote: 'chat.visionUnsupported'.tr(),
                onCancel: ref.read(chatControllerProvider.notifier).cancel,
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
    );
  }
}
