import 'dart:convert';

enum ChatRole { system, user, assistant, tool }

enum ChatMessageStatus { pending, streaming, complete, interrupted, failed }

/// Maximum raw size for a single attachment; compression/downscaling arrives
/// with roadmap item 44.
const maxAttachmentBytes = 10 * 1024 * 1024;

class ChatAttachment {
  const ChatAttachment({
    required this.name,
    required this.mimeType,
    required this.dataBase64,
  });

  factory ChatAttachment.fromStorageJson(Map<dynamic, dynamic> json) =>
      ChatAttachment(
        name: json['name'].toString(),
        mimeType: json['mimeType'].toString(),
        dataBase64: json['dataBase64'].toString(),
      );

  final String name;
  final String mimeType;
  final String dataBase64;

  int get sizeBytes => base64Decode(dataBase64).length;

  Map<String, dynamic> toStorageJson() => {
    'name': name,
    'mimeType': mimeType,
    'dataBase64': dataBase64,
  };

  /// Wire representation for OpenAI-compatible vision requests.
  Map<String, dynamic> toImagePart() => {
    'type': 'image_url',
    'image_url': {'url': 'data:$mimeType;base64,$dataBase64'},
  };

  bool get isImage => mimeType.startsWith('image/');

  /// Text-like documents are inlined into the prompt; anything else cannot be
  /// represented provider-agnostically yet (capability detection: item 45).
  bool get isInlineText =>
      !isImage &&
      (mimeType.startsWith('text/') ||
          const {
            'application/json',
            'application/xml',
            'application/yaml',
            'text/markdown',
          }.contains(mimeType) ||
          <String>[
            '.md',
            '.txt',
            '.csv',
            '.json',
            '.yaml',
            '.yml',
          ].any(name.toLowerCase().endsWith));
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.status = ChatMessageStatus.complete,
    this.toolCalls = const [],
    this.toolCallId,
    this.attachments = const [],
  });

  final String id;
  final ChatRole role;
  final String content;
  final DateTime createdAt;
  final ChatMessageStatus status;
  final List<ChatToolCall> toolCalls;
  final String? toolCallId;
  final List<ChatAttachment> attachments;

  Map<String, dynamic> toJson() => {
    'role': role.name,
    ..._wireContent(),
    if (toolCalls.isNotEmpty)
      'tool_calls': toolCalls.map((call) => call.toJson()).toList(),
    if (toolCallId != null) 'tool_call_id': toolCallId,
  };

  Map<String, dynamic> _wireContent() {
    if (attachments.isEmpty || role != ChatRole.user) {
      return {'content': content};
    }
    final representable = attachments
        .where((a) => a.isImage || a.isInlineText)
        .toList(growable: false);
    if (representable.isEmpty) {
      // Nothing the provider can consume: send plain text so the model at
      // least sees the user's message.
      return {'content': content};
    }
    var text = content;
    for (final attachment in representable) {
      if (!attachment.isImage) {
        final decoded = utf8.decode(base64Decode(attachment.dataBase64));
        text = '$text\n\n```${attachment.name}\n$decoded\n```';
      }
    }
    return {
      'content': [
        {'type': 'text', 'text': text},
        for (final attachment in representable)
          if (attachment.isImage) attachment.toImagePart(),
      ],
    };
  }

  Map<String, dynamic> toStorageJson() => {
    'id': id,
    'role': role.name,
    'content': content,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    if (toolCalls.isNotEmpty)
      'toolCalls': toolCalls.map((call) => call.toJson()).toList(),
    if (toolCallId != null) 'toolCallId': toolCallId,
    if (attachments.isNotEmpty)
      'attachments': attachments.map((a) => a.toStorageJson()).toList(),
  };

  ChatMessage copyWith({
    String? content,
    ChatMessageStatus? status,
    List<ChatToolCall>? toolCalls,
    List<ChatAttachment>? attachments,
  }) => ChatMessage(
    id: id,
    role: role,
    content: content ?? this.content,
    createdAt: createdAt,
    status: status ?? this.status,
    toolCalls: toolCalls ?? this.toolCalls,
    toolCallId: toolCallId,
    attachments: attachments ?? this.attachments,
  );

  factory ChatMessage.fromStorageJson(Map<dynamic, dynamic> json) =>
      ChatMessage(
        id: json['id'].toString(),
        role: ChatRole.values.byName(json['role'].toString()),
        content: json['content']?.toString() ?? '',
        createdAt: DateTime.parse(json['createdAt'].toString()),
        status: ChatMessageStatus.values.byName(
          json['status']?.toString() ?? ChatMessageStatus.complete.name,
        ),
        toolCalls: (json['toolCalls'] as List? ?? const [])
            .whereType<Map>()
            .map(ChatToolCall.fromJson)
            .toList(growable: false),
        toolCallId: json['toolCallId']?.toString(),
        attachments: (json['attachments'] as List? ?? const [])
            .whereType<Map>()
            .map(ChatAttachment.fromStorageJson)
            .toList(growable: false),
      );
}

class ChatToolCall {
  const ChatToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final String arguments;

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
  };

  factory ChatToolCall.fromJson(Map<dynamic, dynamic> json) {
    final function = json['function'];
    if (function is! Map) {
      throw const FormatException('Tool call function is missing');
    }
    return ChatToolCall(
      id: json['id']?.toString() ?? '',
      name: function['name']?.toString() ?? '',
      arguments: function['arguments']?.toString() ?? '',
    );
  }
}

class ChatCompletion {
  const ChatCompletion({required this.content, this.id, this.finishReason});

  final String content;
  final String? id;
  final String? finishReason;
}
