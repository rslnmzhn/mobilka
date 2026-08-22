enum ChatRole { system, user, assistant, tool }

enum ChatMessageStatus { pending, streaming, complete, interrupted, failed }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.status = ChatMessageStatus.complete,
    this.toolCalls = const [],
    this.toolCallId,
  });

  final String id;
  final ChatRole role;
  final String content;
  final DateTime createdAt;
  final ChatMessageStatus status;
  final List<ChatToolCall> toolCalls;
  final String? toolCallId;

  Map<String, dynamic> toJson() => {
    'role': role.name,
    'content': content,
    if (toolCalls.isNotEmpty)
      'tool_calls': toolCalls.map((call) => call.toJson()).toList(),
    if (toolCallId != null) 'tool_call_id': toolCallId,
  };

  Map<String, dynamic> toStorageJson() => {
    'id': id,
    'role': role.name,
    'content': content,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    if (toolCalls.isNotEmpty)
      'toolCalls': toolCalls.map((call) => call.toJson()).toList(),
    if (toolCallId != null) 'toolCallId': toolCallId,
  };

  ChatMessage copyWith({
    String? content,
    ChatMessageStatus? status,
    List<ChatToolCall>? toolCalls,
  }) => ChatMessage(
    id: id,
    role: role,
    content: content ?? this.content,
    createdAt: createdAt,
    status: status ?? this.status,
    toolCalls: toolCalls ?? this.toolCalls,
    toolCallId: toolCallId,
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
