import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:highlight/highlight.dart' as hl;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/workbench_widgets.dart';
import '../../models/application/models_controller.dart';
import '../application/chat_controller.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final composer = TextEditingController();
  final scrollController = ScrollController();

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
          detail: 'HERMES SESSION',
        ),
        leading: Builder(
          builder: (context) => IconButton(
            onPressed: () => Scaffold.of(context).openDrawer(),
            icon: const Icon(Icons.menu),
          ),
        ),
        actions: [
          models.when(
            data: (state) => DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value:
                    state.visibleModels.any(
                      (model) => model.id == state.selectedModelId,
                    )
                    ? state.selectedModelId
                    : null,
                hint: Text('chat.selectModel'.tr()),
                items: state.visibleModels
                    .map(
                      (model) => DropdownMenuItem(
                        value: model.id,
                        child: SizedBox(
                          width: 170,
                          child: Text(
                            model.id,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    ref.read(modelsControllerProvider.notifier).select(value);
                  }
                },
              ),
            ),
            loading: () => const CircularProgressIndicator(),
            error: (_, _) => const SizedBox.shrink(),
          ),
          const SizedBox(width: 12),
        ],
      ),
      drawer: _ConversationsDrawer(chat: chat),
      body: chat.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(error.toString())),
        data: (state) {
          final conversation = state.activeConversation;
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
                    ? _EmptyChat(
                        onCreate: () {
                          final model = models.value?.selectedModelId;
                          if (model != null) {
                            ref
                                .read(chatControllerProvider.notifier)
                                .createConversation(model);
                          }
                        },
                      )
                    : Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 920),
                          child: ListView.builder(
                            controller: scrollController,
                            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                            itemCount: conversation.messages.length,
                            itemBuilder: (context, index) => _MessageCard(
                              key: ValueKey(conversation.messages[index].id),
                              message: conversation.messages[index],
                            ),
                          ),
                        ),
                      ),
              ),
              _ContextIndicator(conversation: conversation, state: state),
              _Composer(
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

class _MessageCard extends StatelessWidget {
  const _MessageCard({super.key, required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    return RepaintBoundary(
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 760),
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isUser
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MarkdownBody(
                data: message.content.isEmpty ? '…' : message.content,
                selectable: true,
                syntaxHighlighter: _CodeHighlighter(
                  Theme.of(context).brightness,
                ),
              ),
              if (message.status != ChatMessageStatus.complete)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    message.status.name,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.isStreaming,
    required this.canSend,
    required this.onSend,
    required this.onCancel,
  });
  final TextEditingController controller;
  final bool isStreaming;
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: TextField(
        controller: controller,
        minLines: 1,
        maxLines: 6,
        onSubmitted: (_) => isStreaming ? onCancel() : onSend(),
        decoration: InputDecoration(
          hintText: 'chat.messageHint'.tr(),
          suffixIcon: IconButton(
            onPressed: isStreaming ? onCancel : (canSend ? onSend : null),
            icon: Icon(isStreaming ? Icons.stop : Icons.arrow_upward),
          ),
        ),
      ),
    ),
  );
}

class _ContextIndicator extends StatelessWidget {
  const _ContextIndicator({required this.conversation, required this.state});
  final Conversation? conversation;
  final ChatState state;

  @override
  Widget build(BuildContext context) {
    final characters =
        conversation?.messages.fold<int>(
          0,
          (sum, message) => sum + message.content.length,
        ) ??
        0;
    final estimate = (characters / 4).ceil();
    final actual = conversation?.usage?.totalTokens;
    final used = actual ?? estimate;
    final limit = conversation?.contextLimitTokens ?? 32768;
    final remaining = (limit - used).clamp(0, limit);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(
          actual == null
              ? '≈ $used / $limit tokens · $remaining left'
              : '$used / $limit tokens · $remaining left',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.auto_awesome, size: 52),
        const SizedBox(height: 12),
        Text(
          'chat.title'.tr(),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add),
          label: Text('chat.newConversation'.tr()),
        ),
      ],
    ),
  );
}

class _ConversationsDrawer extends ConsumerWidget {
  const _ConversationsDrawer({required this.chat});
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

class _CodeHighlighter extends SyntaxHighlighter {
  _CodeHighlighter(this.brightness);
  final Brightness brightness;

  @override
  TextSpan format(String source) {
    final theme = brightness == Brightness.dark
        ? atomOneDarkTheme
        : githubTheme;
    final result = hl.highlight.parse(source, autoDetection: true);
    return TextSpan(
      style: const TextStyle(fontFamily: 'monospace'),
      children: result.nodes?.map((node) => _span(node, theme)).toList(),
    );
  }

  TextSpan _span(hl.Node node, Map<String, TextStyle> theme) {
    final value = node.value;
    if (value != null) {
      return TextSpan(text: value, style: theme[node.className]);
    }
    return TextSpan(
      style: theme[node.className],
      children: node.children?.map((child) => _span(child, theme)).toList(),
    );
  }
}
