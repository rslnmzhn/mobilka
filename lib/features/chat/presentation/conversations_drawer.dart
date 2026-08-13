import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/chat_controller.dart';
import '../domain/conversation.dart';

class ConversationsDrawer extends ConsumerWidget {
  const ConversationsDrawer({required this.chat, super.key});

  final AsyncValue<ChatState> chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Drawer(
    child: SafeArea(
      child: chat.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Text(error.toString()),
        data: (state) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                onChanged: ref.read(chatControllerProvider.notifier).search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'chat.search'.tr(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text('chat.active'.tr())),
                  ButtonSegment(value: true, label: Text('chat.archived'.tr())),
                ],
                selected: {state.showArchived},
                onSelectionChanged: (value) => ref
                    .read(chatControllerProvider.notifier)
                    .setShowArchived(value.first),
              ),
            ),
            Expanded(
              child: ListView(
                children: state.visibleConversations
                    .map(
                      (conversation) => ListTile(
                        selected: conversation.id == state.activeConversationId,
                        title: Text(
                          conversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          ref
                              .read(chatControllerProvider.notifier)
                              .selectConversation(conversation.id);
                          Navigator.pop(context);
                        },
                        trailing: PopupMenuButton<String>(
                          onSelected: (action) =>
                              _handleAction(context, ref, conversation, action),
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'rename',
                              child: Text('chat.rename'.tr()),
                            ),
                            PopupMenuItem(
                              value: conversation.isArchived
                                  ? 'restore'
                                  : 'archive',
                              child: Text(
                                conversation.isArchived
                                    ? 'chat.restore'.tr()
                                    : 'chat.archive'.tr(),
                              ),
                            ),
                            if (conversation.pendingRequestMessageId != null)
                              PopupMenuItem(
                                value: 'retry',
                                child: Text('chat.retry'.tr()),
                              ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('chat.delete'.tr()),
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    Conversation conversation,
    String action,
  ) async {
    final controller = ref.read(chatControllerProvider.notifier);
    if (action == 'archive') {
      await controller.archive(conversation.id);
      return;
    }
    if (action == 'restore') {
      await controller.restore(conversation.id);
      return;
    }
    if (action == 'retry') {
      await controller.retryInterrupted(conversation.id);
      return;
    }
    if (action == 'delete') {
      await controller.delete(conversation.id);
      return;
    }
    final text = TextEditingController(text: conversation.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('chat.rename'.tr()),
        content: TextField(controller: text, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, text.text),
            child: Text('common.save'.tr()),
          ),
        ],
      ),
    );
    text.dispose();
    if (title != null && title.trim().isNotEmpty) {
      await controller.rename(conversation.id, title);
    }
  }
}
