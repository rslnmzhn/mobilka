import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:highlight/highlight.dart' as hl;

import '../domain/chat_message.dart';
import '../domain/tool_execution.dart';
import 'tool_call_card.dart';

class MessageCard extends StatelessWidget {
  const MessageCard({
    super.key,
    required this.message,
    this.toolExecutions = const [],
  });

  final ChatMessage message;
  final List<ToolExecution> toolExecutions;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    final canCopy =
        (isUser || message.role == ChatRole.assistant) &&
        message.content.isNotEmpty;
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
              if (message.reasoningContent.isNotEmpty)
                _ReasoningBlock(text: message.reasoningContent),
              if (message.content.isNotEmpty ||
                  (message.reasoningContent.isEmpty &&
                      message.toolCalls.isEmpty))
                MarkdownBody(
                  data: message.content.isEmpty ? '…' : message.content,
                  selectable: true,
                  syntaxHighlighter: _CodeHighlighter(
                    Theme.of(context).brightness,
                  ),
                ),
              for (final execution in toolExecutions)
                ToolCallCard(
                  key: ValueKey('${execution.call.id}-${execution.callIndex}'),
                  data: ToolCardData.fromExecution(execution),
                ),
              if (message.status != ChatMessageStatus.complete)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    message.status.name,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              if (canCopy)
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    key: Key('copy-message-${message.id}'),
                    tooltip: 'chat.copyMessage'.tr(),
                    onPressed: () => _copyMessage(context),
                    icon: Icon(
                      Icons.copy_outlined,
                      semanticLabel: 'chat.copyMessage'.tr(),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copyMessage(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Clipboard.setData(ClipboardData(text: message.content));
      if (!context.mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text('chat.messageCopied'.tr())),
      );
    } on Object {
      if (!context.mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text('chat.messageCopyFailed'.tr())),
      );
    }
  }
}

class PendingMemoryProposalCard extends StatefulWidget {
  const PendingMemoryProposalCard({
    required this.fileName,
    required this.diff,
    this.isBusy = false,
    required this.onConfirm,
    required this.onReject,
    super.key,
  });

  final String fileName;
  final String diff;
  final bool isBusy;
  final Future<void> Function() onConfirm;
  final Future<void> Function() onReject;

  @override
  State<PendingMemoryProposalCard> createState() =>
      _PendingMemoryProposalCardState();
}

class _PendingMemoryProposalCardState extends State<PendingMemoryProposalCard> {
  var _busy = false;
  String? _error;

  bool get _isBusy => _busy || widget.isBusy;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object {
      if (mounted) setState(() => _error = 'chat.memoryConfirmError'.tr());
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
            if (_error case final error?) ...[
              Text(
                error,
                key: const Key('memory-proposal-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 10),
            ],
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  key: const Key('reject-memory-proposal'),
                  onPressed: _isBusy ? null : () => _run(widget.onReject),
                  child: Text('chat.rejectMemory'.tr()),
                ),
                FilledButton(
                  key: const Key('confirm-memory-proposal'),
                  onPressed: _isBusy ? null : () => _run(widget.onConfirm),
                  child: _isBusy
                      ? const SizedBox.square(
                          key: Key('confirm-memory-proposal-progress'),
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text('chat.confirmMemory'.tr()),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
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

/// Collapsible muted block showing the model's reasoning stream.
class _ReasoningBlock extends StatefulWidget {
  const _ReasoningBlock({required this.text});

  final String text;

  @override
  State<_ReasoningBlock> createState() => _ReasoningBlockState();
}

class _ReasoningBlockState extends State<_ReasoningBlock> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        key: const Key('reasoning-toggle'),
        onTap: () => setState(() => _expanded = !_expanded),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLowest,
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(10),
          ),
          child: _expanded
              ? SelectableText(
                  widget.text,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                    height: 1.35,
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.psychology_outlined,
                      size: 14,
                      color: colors.outline,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'chat.reasoning'.tr(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
