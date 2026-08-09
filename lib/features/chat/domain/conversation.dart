import 'chat_message.dart';
import 'chat_stream_event.dart';

class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.modelId,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
    this.isArchived = false,
    this.pendingRequestMessageId,
    this.contextLimitTokens = 32768,
    this.usage,
  });

  final String id;
  final String title;
  final String modelId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ChatMessage> messages;
  final bool isArchived;
  final String? pendingRequestMessageId;
  final int contextLimitTokens;
  final ConversationUsage? usage;

  Conversation copyWith({
    String? title,
    String? modelId,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
    bool? isArchived,
    String? pendingRequestMessageId,
    bool clearPendingRequest = false,
    int? contextLimitTokens,
    ConversationUsage? usage,
  }) => Conversation(
    id: id,
    title: title ?? this.title,
    modelId: modelId ?? this.modelId,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    messages: messages ?? this.messages,
    isArchived: isArchived ?? this.isArchived,
    pendingRequestMessageId: clearPendingRequest
        ? null
        : (pendingRequestMessageId ?? this.pendingRequestMessageId),
    contextLimitTokens: contextLimitTokens ?? this.contextLimitTokens,
    usage: usage ?? this.usage,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'modelId': modelId,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'isArchived': isArchived,
    'pendingRequestMessageId': pendingRequestMessageId,
    'contextLimitTokens': contextLimitTokens,
    'usage': usage?.toJson(),
    'messages': messages.map((message) => message.toStorageJson()).toList(),
  };

  factory Conversation.fromJson(Map<dynamic, dynamic> json) => Conversation(
    id: json['id'].toString(),
    title: json['title']?.toString() ?? 'New conversation',
    modelId: json['modelId']?.toString() ?? '',
    createdAt: DateTime.parse(json['createdAt'].toString()),
    updatedAt: DateTime.parse(json['updatedAt'].toString()),
    isArchived: json['isArchived'] as bool? ?? false,
    pendingRequestMessageId: json['pendingRequestMessageId']?.toString(),
    contextLimitTokens: json['contextLimitTokens'] as int? ?? 32768,
    usage: json['usage'] is Map
        ? ConversationUsage.fromJson(json['usage'] as Map)
        : null,
    messages: (json['messages'] as List? ?? const [])
        .whereType<Map>()
        .map(ChatMessage.fromStorageJson)
        .toList(),
  );
}

class ConversationUsage {
  const ConversationUsage({
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
  });
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;

  Map<String, dynamic> toJson() => {
    'promptTokens': promptTokens,
    'completionTokens': completionTokens,
    'totalTokens': totalTokens,
  };

  factory ConversationUsage.fromJson(Map<dynamic, dynamic> json) =>
      ConversationUsage(
        promptTokens: json['promptTokens'] as int?,
        completionTokens: json['completionTokens'] as int?,
        totalTokens: json['totalTokens'] as int?,
      );

  factory ConversationUsage.fromChatUsage(ChatUsage usage) => ConversationUsage(
    promptTokens: usage.promptTokens,
    completionTokens: usage.completionTokens,
    totalTokens: usage.totalTokens,
  );
}
