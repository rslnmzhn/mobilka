import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/application/models_controller.dart';
import '../../models/domain/model_capabilities.dart';
import '../../artifacts/application/artifact_link_opener.dart';
import '../application/chat_controller.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import '../domain/tool_execution.dart';
import 'chat_composer.dart';
import 'chat_message_widgets.dart';
import 'chat_navigation_swipe_access.dart';
import 'pending_skill_proposal_card.dart';

class ChatScreenBody extends ConsumerWidget {
  const ChatScreenBody({
    required this.chat,
    required this.models,
    required this.composer,
    required this.scrollController,
    required this.onCreateConversation,
    required this.onPointerSignal,
    required this.onScrollNotification,
    required this.onSend,
    required this.onShowNavigation,
    super.key,
  });

  final AsyncValue<ChatState> chat;
  final AsyncValue<ModelsState> models;
  final TextEditingController composer;
  final ScrollController scrollController;
  final VoidCallback onCreateConversation;
  final ValueChanged<PointerSignalEvent> onPointerSignal;
  final NotificationListenerCallback<ScrollNotification> onScrollNotification;
  final void Function(String text, List<ChatAttachment> attachments) onSend;
  final VoidCallback onShowNavigation;

  @override
  Widget build(BuildContext context, WidgetRef ref) => chat.when(
    loading: () => const Center(child: CircularProgressIndicator()),
    error: (error, _) => Center(child: Text(error.toString())),
    data: (state) => _ChatContent(
      state: state,
      models: models,
      composer: composer,
      scrollController: scrollController,
      onCreateConversation: onCreateConversation,
      onPointerSignal: onPointerSignal,
      onScrollNotification: onScrollNotification,
      onSend: onSend,
      onShowNavigation: onShowNavigation,
    ),
  );
}

class _ChatContent extends ConsumerWidget {
  const _ChatContent({
    required this.state,
    required this.models,
    required this.composer,
    required this.scrollController,
    required this.onCreateConversation,
    required this.onPointerSignal,
    required this.onScrollNotification,
    required this.onSend,
    required this.onShowNavigation,
  });

  final ChatState state;
  final AsyncValue<ModelsState> models;
  final TextEditingController composer;
  final ScrollController scrollController;
  final VoidCallback onCreateConversation;
  final ValueChanged<PointerSignalEvent> onPointerSignal;
  final NotificationListenerCallback<ScrollNotification> onScrollNotification;
  final void Function(String text, List<ChatAttachment> attachments) onSend;
  final VoidCallback onShowNavigation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversation = state.activeConversation;
    return Column(
      children: [
        if (state.errorMessage != null)
          _ErrorBanner(message: state.errorMessage!),
        Expanded(
          child: ChatNavigationSwipeAccess(
            isEligible: () =>
                conversation == null ||
                conversation.messages.isEmpty ||
                (scrollController.hasClients &&
                    scrollController.position.pixels <=
                        scrollController.position.minScrollExtent + 4),
            onShowNavigation: onShowNavigation,
            child: _MessageList(
              conversation: conversation,
              scrollController: scrollController,
              onCreateConversation: onCreateConversation,
              onPointerSignal: onPointerSignal,
              onScrollNotification: onScrollNotification,
            ),
          ),
        ),
        _PendingProposals(state: state),
        ChatComposer(
          controller: composer,
          isStreaming: state.isStreaming,
          canSend:
              models.value?.selectedModelId != null || conversation != null,
          visionSupported: ModelCapabilityResolver.resolve(
            conversation?.modelId ?? models.value?.selectedModelId ?? '',
          ).vision,
          visionNote: 'chat.visionUnsupported'.tr(),
          onCancel: ref.read(chatControllerProvider.notifier).cancel,
          onSend: onSend,
        ),
      ],
    );
  }
}

class _ErrorBanner extends ConsumerWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialBanner(
    content: Text(message),
    actions: [
      TextButton(
        onPressed: ref.read(chatControllerProvider.notifier).dismissError,
        child: Text('common.close'.tr()),
      ),
    ],
  );
}

class _MessageList extends ConsumerWidget {
  const _MessageList({
    required this.conversation,
    required this.scrollController,
    required this.onCreateConversation,
    required this.onPointerSignal,
    required this.onScrollNotification,
  });

  final Conversation? conversation;
  final ScrollController scrollController;
  final VoidCallback onCreateConversation;
  final ValueChanged<PointerSignalEvent> onPointerSignal;
  final NotificationListenerCallback<ScrollNotification> onScrollNotification;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (conversation == null || conversation!.messages.isEmpty) {
      return EmptyChat(onCreate: onCreateConversation);
    }
    final messages = conversation!.messages
        .where((message) => message.role != ChatRole.tool)
        .toList();
    final executions = projectToolExecutions(conversation);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: Listener(
          onPointerSignal: onPointerSignal,
          child: NotificationListener<ScrollNotification>(
            onNotification: onScrollNotification,
            child: ListView.builder(
              controller: scrollController,
              reverse: true,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              itemCount: messages.length,
              itemBuilder: (_, index) => _messageCard(
                ref,
                messages[messages.length - 1 - index],
                executions,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _messageCard(
    WidgetRef ref,
    ChatMessage message,
    List<ToolExecution> executions,
  ) => MessageCard(
    key: ValueKey(message.id),
    message: message,
    renderingConversationId: conversation!.id,
    artifactLinkOpener: ref.read(artifactLinkOpenerProvider),
    onSendAgain: message.role == ChatRole.user
        ? () => ref
              .read(chatControllerProvider.notifier)
              .sendAgain(conversation!.id, message.id)
        : null,
    toolExecutions: executions
        .where((item) => item.assistantMessageId == message.id)
        .toList(growable: false),
  );
}

class _PendingProposals extends ConsumerWidget {
  const _PendingProposals({required this.state});
  final ChatState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversation = state.activeConversation;
    final controller = ref.read(chatControllerProvider.notifier);
    return Column(
      children: [
        if (conversation?.pendingMemoryProposal case final proposal?)
          PendingMemoryProposalCard(
            fileName: proposal.fileName,
            diff: proposal.diff,
            isBusy: state.confirmingMemoryToolCallId == proposal.toolCallId,
            onConfirm: controller.confirmPendingMemoryProposal,
            onReject: controller.rejectPendingMemoryProposal,
          ),
        if (conversation?.pendingToolProposal case final proposal?)
          PendingToolProposalCard(
            toolName: proposal.call.name,
            isBusy: state.confirmingToolCallId == proposal.call.id,
            onConfirm: controller.confirmPendingToolProposal,
            onReject: controller.rejectPendingToolProposal,
          ),
        if (conversation?.pendingSkillProposal case final proposal?)
          PendingSkillProposalCard(
            name: proposal.name,
            oldContent: proposal.oldContent,
            proposedContent: proposal.proposedContent,
            sourceDerived: proposal.sourceDerived,
            warningCount: proposal.warnings.length,
            isBusy: state.confirmingSkillName == proposal.name,
            onConfirm: controller.confirmPendingSkillProposal,
            onReject: controller.rejectPendingSkillProposal,
          ),
      ],
    );
  }
}
