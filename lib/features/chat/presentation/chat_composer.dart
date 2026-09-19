import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/chat_message.dart';
import '../application/image_attachment_processor.dart';

/// Callback picking attachments and returning raw bytes + metadata; injectable
/// for widget tests. Supports returning a single [ChatAttachment], a [List<ChatAttachment>],
/// or null if cancelled.
typedef AttachmentPicker =
    Future<Object?> Function({required bool image});

class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.isStreaming,
    required this.canSend,
    required this.onSend,
    required this.onCancel,
    this.pickAttachment,
    this.visionSupported = true,
    this.visionNote = '',
  });

  final TextEditingController controller;
  final bool isStreaming;
  final bool canSend;
  final void Function(String text, List<ChatAttachment> attachments) onSend;
  final VoidCallback onCancel;

  /// Defaults to the system picker (file_selector / Android SAF intent).
  final AttachmentPicker? pickAttachment;

  /// Whether the active conversation's model accepts image inputs; disables
  /// the image attachment entry otherwise (roadmap item 45).
  final bool visionSupported;

  final String visionNote;

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
      final picked = await picker(image: image);
      if (picked == null) return;
      final List<ChatAttachment> list;
      if (picked is List<ChatAttachment>) {
        list = picked;
      } else if (picked is ChatAttachment) {
        list = [picked];
      } else if (picked is Iterable) {
        list = picked.whereType<ChatAttachment>().toList();
      } else {
        list = const [];
      }
      if (list.isEmpty) return;
      setState(() => attachments.addAll(list));
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<List<ChatAttachment>> _pickViaSystemSelector({required bool image}) async {
    if (image && defaultTargetPlatform == TargetPlatform.android) {
      final galleryResults = await _pickImagesViaAndroidGallery();
      if (galleryResults != null) {
        return galleryResults;
      }
    }

    const imageGroup = XTypeGroup(
      label: 'images',
      mimeTypes: [
        'image/png',
        'image/jpeg',
        'image/webp',
        'image/gif',
        'image/heic',
        'image/heif',
        'image/*',
      ],
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'heic', 'heif'],
    );
    const documentGroup = XTypeGroup(
      label: 'documents',
      mimeTypes: ['*/*'],
      extensions: [
        'txt',
        'md',
        'json',
        'csv',
        'yaml',
        'yml',
        'xml',
        'docx',
        'pdf',
        'xlsx',
      ],
    );

    final files = await openFiles(
      acceptedTypeGroups: [image ? imageGroup : documentGroup],
    );
    if (files.isEmpty) return const [];

    final list = <ChatAttachment>[];
    for (final file in files) {
      final processed = await _processFile(file);
      if (processed != null) {
        list.add(processed);
      }
    }
    return list;
  }

  Future<List<ChatAttachment>?> _pickImagesViaAndroidGallery() async {
    try {
      const channel = MethodChannel('com.rslnmzhn.mobilka/gallery');
      final rawList = await channel.invokeMethod<List<dynamic>>('pickImages');
      if (rawList == null) return null;
      final list = <ChatAttachment>[];
      for (final item in rawList) {
        if (item is Map) {
          final path = item['path'] as String?;
          final name = item['name'] as String? ?? 'image.jpg';
          final mimeType = item['mimeType'] as String? ?? 'image/jpeg';
          if (path != null) {
            final file = XFile(path, name: name, mimeType: mimeType);
            final processed = await _processFile(file);
            if (processed != null) {
              list.add(processed);
            }
          }
        }
      }
      return list;
    } catch (_) {
      return null;
    }
  }

  Future<ChatAttachment?> _processFile(XFile file) async {
    final rawBytes = await file.readAsBytes();
    if (rawBytes.isEmpty) return null;
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
      'heic' => 'image/heic',
      'heif' => 'image/heif',
      'txt' || 'md' || 'csv' => 'text/plain',
      'json' => 'application/json',
      'yaml' || 'yml' => 'application/yaml',
      'pdf' => 'application/pdf',
      'docx' =>
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xlsx' =>
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'xml' => 'application/xml',
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
                filled: false,
                fillColor: Colors.transparent,
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
                      enabled: widget.visionSupported && !widget.isStreaming,
                      child: Text(
                        'chat.attachImage'.tr() +
                            (widget.visionSupported
                                ? ''
                                : ' (${widget.visionNote})'),
                      ),
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

  bool get _canSend =>
      widget.canSend &&
      !widget.isStreaming &&
      (widget.controller.text.trim().isNotEmpty || attachments.isNotEmpty);
}
