import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/workbench_widgets.dart';
import '../../models/application/models_controller.dart';
import '../application/chat_controller.dart';
import '../domain/chat_message.dart';
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
    await ref.read(modelsControllerProvider.notifier).select(modelId);
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
            data: (state) => ModelPickerButton(
              modelId:
                  state.visibleModels.any(
                    (model) => model.id == state.selectedModelId,
                  )
                  ? state.selectedModelId
                  : null,
              onPressed: () => _selectModel(state),
            ),
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
          const SizedBox(width: 4),
        ],
      ),
      drawer: ConversationsDrawer(chat: chat),
      body: chat.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(error.toString())),
        data: (state) {
          final conversation = state.activeConversation;
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
                          child: ListView.builder(
                            controller: scrollController,
                            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                            itemCount: messages!.length,
                            itemBuilder: (context, index) => MessageCard(
                              key: ValueKey(messages[index].id),
                              message: messages[index],
                            ),
                          ),
                        ),
                      ),
              ),
              if (conversation?.pendingMemoryProposal case final proposal?)
                PendingMemoryProposalCard(
                  fileName: proposal.fileName,
                  diff: proposal.diff,
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
                onCancel: ref.read(chatControllerProvider.notifier).cancel,
                onSend: () {
                  final text = composer.text;
                  composer.clear();
                  ref.read(chatControllerProvider.notifier).send(text);
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
