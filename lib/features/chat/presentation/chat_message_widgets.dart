import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:highlight/highlight.dart' as hl;

import '../domain/chat_message.dart';
import '../domain/tool_execution.dart';
import 'tool_call_card.dart';
import 'message_actions.dart';

class MessageCard extends StatelessWidget {
  const MessageCard({
    super.key,
    required this.message,
    this.toolExecutions = const [],
    this.onSendAgain,
  });

  final ChatMessage message;
  final List<ToolExecution> toolExecutions;
  final VoidCallback? onSendAgain;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    final canCopy =
        (isUser || message.role == ChatRole.assistant) &&
        message.content.isNotEmpty;
    return RepaintBoundary(
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: isUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              button: canCopy,
              label: canCopy ? 'openMessageActions'.tr() : null,
              customSemanticsActions: canCopy
                  ? {
                      CustomSemanticsAction(
                        label: 'openMessageActions'.tr(),
                      ): () =>
                          _showActions(context),
                    }
                  : null,
              child: FocusableActionDetector(
                enabled: canCopy,
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                  SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
                },
                actions: {
                  ActivateIntent: CallbackAction<ActivateIntent>(
                    onInvoke: (_) {
                      _showActions(context);
                      return null;
                    },
                  ),
                },
                child: Listener(
                  onPointerDown: canCopy
                      ? (event) {
                          if ((event.buttons & kSecondaryMouseButton) != 0) {
                            _showActions(context);
                          }
                        }
                      : null,
                  child: Container(
                    key: Key('message-bubble-${message.id}'),
                    constraints: const BoxConstraints(maxWidth: 760),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: isUser
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Theme.of(context).colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Stack(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (message.reasoningContent.isNotEmpty)
                                _ReasoningBlock(text: message.reasoningContent),
                              if (message.content.isNotEmpty ||
                                  (message.reasoningContent.isEmpty &&
                                      message.toolCalls.isEmpty))
                                MarkdownBody(
                                  key: Key('message-markdown-${message.id}'),
                                  data: message.content.isEmpty
                                      ? '…'
                                      : message.content,
                                  selectable: true,
                                  syntaxHighlighter: _CodeHighlighter(
                                    Theme.of(context).brightness,
                                  ),
                                ),
                              for (final execution in toolExecutions)
                                ToolCallCard(
                                  key: ValueKey(
                                    '${execution.call.id}-${execution.callIndex}',
                                  ),
                                  data: ToolCardData.fromExecution(execution),
                                ),
                              if (message.status != ChatMessageStatus.complete)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    message.status.name,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelSmall,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (canCopy) ...[
                          _PaddingLongPress(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: 14,
                            onLongPress: () => _showActions(context),
                          ),
                          _PaddingLongPress(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            height: 14,
                            onLongPress: () => _showActions(context),
                          ),
                          _PaddingLongPress(
                            top: 14,
                            bottom: 14,
                            left: 0,
                            width: 14,
                            onLongPress: () => _showActions(context),
                          ),
                          _PaddingLongPress(
                            top: 14,
                            bottom: 14,
                            right: 0,
                            width: 14,
                            onLongPress: () => _showActions(context),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showActions(BuildContext context) => showMessageActions(
    context,
    message: message,
    onSendAgain: message.role == ChatRole.user ? onSendAgain : null,
  );
}

class _PaddingLongPress extends StatelessWidget {
  const _PaddingLongPress({
    required this.onLongPress,
    this.top,
    this.bottom,
    this.left,
    this.right,
    this.width,
    this.height,
  });

  final VoidCallback onLongPress;
  final double? top;
  final double? bottom;
  final double? left;
  final double? right;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) => Positioned(
    top: top,
    bottom: bottom,
    left: left,
    right: right,
    child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: onLongPress,
      child: SizedBox(width: width, height: height),
    ),
  );
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

class PendingToolProposalCard extends StatefulWidget {
  const PendingToolProposalCard({
    required this.toolName,
    required this.isBusy,
    required this.onConfirm,
    required this.onReject,
    super.key,
  });
  final String toolName;
  final bool isBusy;
  final Future<void> Function() onConfirm;
  final Future<void> Function() onReject;

  @override
  State<PendingToolProposalCard> createState() =>
      _PendingToolProposalCardState();
}

class _PendingToolProposalCardState extends State<PendingToolProposalCard> {
  var _busy = false;
  Future<void> _run(Future<void> Function() action) async {
    if (_busy || widget.isBusy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('pending-tool-proposal'),
    margin: const EdgeInsets.fromLTRB(20, 8, 20, 4),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'chat.memoryProposal'.tr(args: [widget.toolName]),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                key: const Key('reject-tool-proposal'),
                onPressed: _busy || widget.isBusy
                    ? null
                    : () => _run(widget.onReject),
                child: Text('chat.rejectMemory'.tr()),
              ),
              FilledButton(
                key: const Key('confirm-tool-proposal'),
                onPressed: _busy || widget.isBusy
                    ? null
                    : () => _run(widget.onConfirm),
                child: Text('chat.confirmMemory'.tr()),
              ),
            ],
          ),
        ],
      ),
    ),
  );
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
