import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/chat_message.dart';
import '../application/image_attachment_processor.dart';

/// Callback picking one file and returning raw bytes + metadata; injectable
/// for widget tests.
typedef AttachmentPicker =
    Future<ChatAttachment?> Function({required bool image});

class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.isStreaming,
    required this.canSend,
    required this.onSend,
    required this.onCancel,
    this.pickAttachment,
  });

  final TextEditingController controller;
  final bool isStreaming;
  final bool canSend;
  final void Function(String text, List<ChatAttachment> attachments) onSend;
  final VoidCallback onCancel;

  /// Defaults to the system picker (file_selector / Android SAF intent).
  final AttachmentPicker? pickAttachment;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final attachments = <ChatAttachment>[];
  final _imageProcessor = const ImageAttachmentProcessor();

  bool get _usesMobileKeyboardAction =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  void _insertNewline() {
    final value = widget.controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    widget.controller.value = value.copyWith(
      text: value.text.replaceRange(start, end, '\n'),
      selection: TextSelection.collapsed(offset: start + 1),
      composing: TextRange.empty,
    );
  }

  Future<void> _attach({required bool image}) async {
    final picker = widget.pickAttachment ?? _pickViaSystemSelector;
    try {
      final attachment = await picker(image: image);
      if (attachment == null) return;
      setState(() => attachments.add(attachment));
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<ChatAttachment?> _pickViaSystemSelector({required bool image}) async {
    const imageGroup = XTypeGroup(
      label: 'images',
      mimeTypes: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'],
    );
    const textGroup = XTypeGroup(
      label: 'documents',
      mimeTypes: ['text/*', 'application/json'],
    );
    final file = await openFile(
      acceptedTypeGroups: [image ? imageGroup : textGroup],
    );
    if (file == null) return null;
    final rawBytes = await file.readAsBytes();
    var name = file.name;
    var mimeType =
        file.mimeType ??
        _mimeTypeFromName(file.name) ??
        'application/octet-stream';
    var bytes = rawBytes;
    if (mimeType.startsWith('image/')) {
      final processed = _imageProcessor.process(
        name: name,
        mimeType: mimeType,
        bytes: rawBytes,
      );
      bytes = processed.bytes;
      name = processed.name;
      mimeType = processed.mimeType;
    }
    // Guard applies to the payload actually sent, post-compression.
    _validateSize(bytes.length);
    return ChatAttachment(
      name: name,
      mimeType: mimeType,
      dataBase64: base64Encode(bytes),
    );
  }

  void _validateSize(int length) {
    if (length > maxAttachmentBytes) {
      throw StateError('chat.attachmentTooLarge'.tr());
    }
  }

  String? _mimeTypeFromName(String name) {
    final extension = name.split('.').last.toLowerCase();
    return switch (extension) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'txt' || 'md' || 'csv' => 'text/plain',
      'json' => 'application/json',
      'yaml' || 'yml' => 'application/yaml',
      _ => null,
    };
  }

  void _send() {
    widget.onSend(widget.controller.text, List.unmodifiable(attachments));
    // The caller owns the text controller lifecycle; only local chips reset.
    setState(attachments.clear);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (attachments.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: attachments.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final attachment = attachments[index];
                  return InputChip(
                    key: Key('attachment-chip-$index'),
                    avatar: Icon(
                      attachment.isImage
                          ? Icons.image_outlined
                          : Icons.description_outlined,
                      size: 18,
                    ),
                    label: Text(attachment.name),
                    deleteIcon: const Icon(Icons.close, size: 18),
                    onDeleted: () =>
                        setState(() => attachments.removeAt(index)),
                  );
                },
              ),
            ),
          CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.enter): () {
                if (_canSend) _send();
              },
              const SingleActivator(LogicalKeyboardKey.enter, shift: true):
                  _insertNewline,
            },
            child: TextField(
              controller: widget.controller,
              minLines: 1,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              textInputAction: _usesMobileKeyboardAction
                  ? TextInputAction.send
                  : TextInputAction.newline,
              onSubmitted: (_) {
                if (_canSend) _send();
              },
              decoration: InputDecoration(
                hintText: 'chat.messageHint'.tr(),
                prefixIcon: PopupMenuButton<String>(
                  key: const Key('attachment-menu'),
                  tooltip: 'chat.attach'.tr(),
                  enabled: !widget.isStreaming,
                  icon: const Icon(Icons.attach_file),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      key: const Key('attach-image'),
                      value: 'image',
                      child: Text('chat.attachImage'.tr()),
                    ),
                    PopupMenuItem(
                      key: const Key('attach-document'),
                      value: 'document',
                      child: Text('chat.attachDocument'.tr()),
                    ),
                  ],
                  onSelected: (value) {
                    _attach(image: value == 'image');
                  },
                ),
                suffixIcon: IconButton(
                  onPressed: widget.isStreaming
                      ? widget.onCancel
                      : (_canSend ? _send : null),
                  icon: Icon(
                    widget.isStreaming ? Icons.stop : Icons.arrow_upward,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  bool get _canSend => widget.canSend && !widget.isStreaming;
}
