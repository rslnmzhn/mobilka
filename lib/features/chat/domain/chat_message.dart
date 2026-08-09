enum ChatRole { system, user, assistant, tool }

enum ChatMessageStatus { pending, streaming, complete, interrupted, failed }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.status = ChatMessageStatus.complete,
  });

  final String id;
  final ChatRole role;
  final String content;
  final DateTime createdAt;
  final ChatMessageStatus status;

  Map<String, dynamic> toJson() => {'role': role.name, 'content': content};

  Map<String, dynamic> toStorageJson() => {
    'id': id,
    'role': role.name,
    'content': content,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
  };

  ChatMessage copyWith({String? content, ChatMessageStatus? status}) =>
      ChatMessage(
        id: id,
        role: role,
        content: content ?? this.content,
        createdAt: createdAt,
        status: status ?? this.status,
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
      );
}

class ChatCompletion {
  const ChatCompletion({required this.content, this.id, this.finishReason});

  final String content;
  final String? id;
  final String? finishReason;
}
