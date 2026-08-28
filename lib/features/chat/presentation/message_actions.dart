import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/chat_message.dart';

Future<void> showMessageActions(
  BuildContext context, {
  required ChatMessage message,
  required VoidCallback? onSendAgain,
}) async {
  final canCopy =
      message.content.isNotEmpty &&
      (message.role == ChatRole.user || message.role == ChatRole.assistant);
  if (!canCopy) return;
  final action = await showDialog<_MessageAction>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('messageActions'.tr()),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            key: Key('copy-message-${message.id}'),
            leading: const Icon(Icons.copy_outlined),
            title: Text('chat.copyMessage'.tr()),
            onTap: () => Navigator.pop(context, _MessageAction.copy),
          ),
          if (message.role == ChatRole.user && onSendAgain != null)
            ListTile(
              key: Key('send-again-${message.id}'),
              leading: const Icon(Icons.replay_outlined),
              title: Text('sendAgain'.tr()),
              onTap: () => Navigator.pop(context, _MessageAction.sendAgain),
            ),
        ],
      ),
    ),
  );
  if (!context.mounted || action == null) return;
  if (action == _MessageAction.sendAgain) {
    onSendAgain?.call();
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  try {
    await Clipboard.setData(ClipboardData(text: message.content));
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text('chat.messageCopied'.tr())));
  } on Object {
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text('chat.messageCopyFailed'.tr())),
    );
  }
}

enum _MessageAction { copy, sendAgain }
