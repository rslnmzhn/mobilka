import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:highlight/highlight.dart' as hl;

import '../../../core/links/external_link_launcher.dart';
import '../../../core/links/external_link_policy.dart';
import '../../artifacts/application/artifact_link_opener.dart';
import '../../artifacts/domain/artifact_link.dart';
import '../../artifacts/presentation/artifact_feedback.dart';
import '../domain/chat_message.dart';
import '../domain/tool_execution.dart';
import 'tool_call_card.dart';
import 'message_actions.dart';
export 'pending_confirmation_cards.dart';

class MessageCard extends StatelessWidget {
  const MessageCard({
    super.key,
    required this.message,
    this.toolExecutions = const [],
    this.onSendAgain,
    this.externalLinkLauncher = const UrlExternalLinkLauncher(),
    this.artifactLinkOpener,
    this.artifactLinkOpen,
    this.renderingConversationId,
  });

  final ChatMessage message;
  final List<ToolExecution> toolExecutions;
  final VoidCallback? onSendAgain;
  final ExternalLinkLauncher externalLinkLauncher;
  final ArtifactLinkOpener? artifactLinkOpener;
  final ArtifactLinkOpenCallback? artifactLinkOpen;
  final String? renderingConversationId;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    final canCopy =
        (isUser || message.role == ChatRole.assistant) &&
        message.content.isNotEmpty;
    return RepaintBoundary(child: _alignedCard(context, isUser, canCopy));
  }

  Widget _alignedCard(BuildContext context, bool isUser, bool canCopy) => Align(
    alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
    child: Semantics(
      button: canCopy,
      label: canCopy ? 'openMessageActions'.tr() : null,
      customSemanticsActions: canCopy
          ? {
              CustomSemanticsAction(label: 'openMessageActions'.tr()): () =>
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
          child: _MessageBubble(
            message: message,
            isUser: isUser,
            canCopy: canCopy,
            toolExecutions: toolExecutions,
            onActions: () => _showActions(context),
            onLink: (href) => _dispatchLink(context, href),
          ),
        ),
      ),
    ),
  );

  Future<void> _showActions(BuildContext context) => showMessageActions(
    context,
    message: message,
    onSendAgain: message.role == ChatRole.user ? onSendAgain : null,
  );

  Future<void> _dispatchLink(BuildContext context, String? href) async {
    if (href != null && ArtifactLink.claimsScheme(href)) {
      final link = ArtifactLink.tryParse(href);
      final open = artifactLinkOpen ?? artifactLinkOpener?.open;
      if (link == null || open == null) {
        _showLinkFeedback(context, 'artifacts.link.invalid'.tr());
        return;
      }
      final result = await open(
        link,
        scope: ArtifactOpenScope.chat,
        conversationId: renderingConversationId,
      );
      if (!context.mounted || result == ArtifactLinkOpenResult.opened) return;
      _showLinkFeedback(context, artifactOpenMessageKey(result).tr());
      return;
    }
    final uri = href == null
        ? null
        : const ExternalLinkPolicy().canonicalize(href);
    if (uri == null) {
      _showLinkFeedback(context, 'invalidExternalLink'.tr());
      return;
    }
    try {
      if (!await externalLinkLauncher.launch(uri) && context.mounted) {
        _showLinkFeedback(context, 'externalLinkLaunchFailed'.tr());
      }
    } on Object {
      if (context.mounted) {
        _showLinkFeedback(context, 'externalLinkLaunchFailed'.tr());
      }
    }
  }

  void _showLinkFeedback(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.isUser,
    required this.canCopy,
    required this.toolExecutions,
    required this.onActions,
    required this.onLink,
  });
  final ChatMessage message;
  final bool isUser;
  final bool canCopy;
  final List<ToolExecution> toolExecutions;
  final VoidCallback onActions;
  final ValueChanged<String?> onLink;

  @override
  Widget build(BuildContext context) => Container(
    key: Key('message-bubble-${message.id}'),
    constraints: const BoxConstraints(maxWidth: 760),
    margin: const EdgeInsets.only(bottom: 12),
    decoration: BoxDecoration(
      color: isUser
          ? Theme.of(context).colorScheme.primaryContainer
          : Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Stack(children: [_content(context), ..._actionRegions]),
  );

  Widget _content(BuildContext context) => Padding(
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message.reasoningContent.isNotEmpty)
          _ReasoningBlock(text: message.reasoningContent),
        if (message.content.isNotEmpty ||
            (message.reasoningContent.isEmpty && message.toolCalls.isEmpty))
          MarkdownBody(
            key: Key('message-markdown-${message.id}'),
            data: message.content.isEmpty ? '…' : message.content,
            selectable: true,
            onTapLink: (text, href, title) => onLink(href),
            styleSheet: MarkdownStyleSheet(
              a: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                decoration: TextDecoration.underline,
              ),
            ),
            syntaxHighlighter: _CodeHighlighter(Theme.of(context).brightness),
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
      ],
    ),
  );

  List<Widget> get _actionRegions => canCopy
      ? [
          _PaddingLongPress(
            top: 0,
            left: 0,
            right: 0,
            height: 14,
            onLongPress: onActions,
          ),
          _PaddingLongPress(
            bottom: 0,
            left: 0,
            right: 0,
            height: 14,
            onLongPress: onActions,
          ),
          _PaddingLongPress(
            top: 14,
            bottom: 14,
            left: 0,
            width: 14,
            onLongPress: onActions,
          ),
          _PaddingLongPress(
            top: 14,
            bottom: 14,
            right: 0,
            width: 14,
            onLongPress: onActions,
          ),
        ]
      : const [];
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
      child: _toggle(colors),
    );
  }

  Widget _toggle(ColorScheme colors) => InkWell(
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
  );
}
