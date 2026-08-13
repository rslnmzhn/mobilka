import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:highlight/highlight.dart' as hl;

import '../application/chat_controller.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';

class MessageCard extends StatelessWidget {
  const MessageCard({super.key, required this.message});

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
                data: message.content.isEmpty
                    ? (message.toolCalls.isEmpty
                          ? '…'
                          : message.toolCalls
                                .map((call) => '`Tool: ${call.name}`')
                                .join('\n'))
                    : message.content,
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

class PendingMemoryProposalCard extends StatefulWidget {
  const PendingMemoryProposalCard({
    required this.fileName,
    required this.diff,
    required this.onConfirm,
    required this.onReject,
    super.key,
  });

  final String fileName;
  final String diff;
  final Future<void> Function() onConfirm;
  final Future<void> Function() onReject;

  @override
  State<PendingMemoryProposalCard> createState() =>
      _PendingMemoryProposalCardState();
}

class _PendingMemoryProposalCardState extends State<PendingMemoryProposalCard> {
  var _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 920),
    child: Card(
      key: const Key('pending-memory-proposal'),
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'chat.memoryProposal'.tr(args: [widget.fileName]),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              padding: const EdgeInsets.all(12),
              color: Theme.of(context).colorScheme.surfaceContainerLowest,
              child: SingleChildScrollView(
                child: SelectableText(
                  widget.diff,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  key: const Key('reject-memory-proposal'),
                  onPressed: _busy ? null : () => _run(widget.onReject),
                  child: Text('chat.rejectMemory'.tr()),
                ),
                FilledButton(
                  key: const Key('confirm-memory-proposal'),
                  onPressed: _busy ? null : () => _run(widget.onConfirm),
                  child: Text('chat.confirmMemory'.tr()),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class ContextIndicator extends StatelessWidget {
  const ContextIndicator({
    required this.conversation,
    required this.state,
    super.key,
  });

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

class EmptyChat extends StatelessWidget {
  const EmptyChat({required this.onCreate, super.key});

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
