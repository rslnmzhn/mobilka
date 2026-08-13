import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ChatComposer extends StatelessWidget {
  const ChatComposer({
    super.key,
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

  bool get _usesMobileKeyboardAction =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  void _insertNewline() {
    final value = controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    controller.value = value.copyWith(
      text: value.text.replaceRange(start, end, '\n'),
      selection: TextSelection.collapsed(offset: start + 1),
      composing: TextRange.empty,
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter): () {
            if (canSend && !isStreaming) onSend();
          },
          const SingleActivator(LogicalKeyboardKey.enter, shift: true):
              _insertNewline,
        },
        child: TextField(
          controller: controller,
          minLines: 1,
          maxLines: 6,
          keyboardType: TextInputType.multiline,
          textInputAction: _usesMobileKeyboardAction
              ? TextInputAction.send
              : TextInputAction.newline,
          onSubmitted: (_) {
            if (canSend && !isStreaming) onSend();
          },
          decoration: InputDecoration(
            hintText: 'chat.messageHint'.tr(),
            suffixIcon: IconButton(
              onPressed: isStreaming ? onCancel : (canSend ? onSend : null),
              icon: Icon(isStreaming ? Icons.stop : Icons.arrow_upward),
            ),
          ),
        ),
      ),
    ),
  );
}
