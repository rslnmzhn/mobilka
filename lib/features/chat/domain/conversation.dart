import 'chat_message.dart';
import 'chat_stream_event.dart';
import 'pending_memory_proposal.dart';
import 'pending_tool_proposal.dart';

enum ConversationTitleState { pendingAutomatic, generated, fallback, manual }

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
    this.pendingMemoryProposal,
    this.sessionKey,
    this.titleState = ConversationTitleState.manual,
    this.publicSourceWireBytesUsed = 0,
    this.pendingToolProposal,
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
  final PendingMemoryProposal? pendingMemoryProposal;
  final String? sessionKey;
  final ConversationTitleState titleState;
  final int publicSourceWireBytesUsed;
  final PendingToolProposal? pendingToolProposal;

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
    PendingMemoryProposal? pendingMemoryProposal,
    bool clearPendingMemoryProposal = false,
    ConversationTitleState? titleState,
    int? publicSourceWireBytesUsed,
    PendingToolProposal? pendingToolProposal,
    bool clearPendingToolProposal = false,
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
    pendingMemoryProposal: clearPendingMemoryProposal
        ? null
        : (pendingMemoryProposal ?? this.pendingMemoryProposal),
    sessionKey: sessionKey,
    titleState: titleState ?? this.titleState,
    publicSourceWireBytesUsed:
        publicSourceWireBytesUsed ?? this.publicSourceWireBytesUsed,
    pendingToolProposal: clearPendingToolProposal
        ? null
        : (pendingToolProposal ?? this.pendingToolProposal),
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
    'pendingMemoryProposal': pendingMemoryProposal?.toJson(),
    'sessionKey': sessionKey,
    'titleState': titleState.name,
    'publicSourceWireBytesUsed': publicSourceWireBytesUsed,
    'pendingToolProposal': pendingToolProposal?.toJson(),
    'messages': messages.map((message) => message.toStorageJson()).toList(),
  };

  factory Conversation.fromJson(Map<dynamic, dynamic> json) {
    final id = json['id'].toString();
    final title = json['title']?.toString() ?? 'New conversation';
    final createdAt = DateTime.parse(json['createdAt'].toString());
    return Conversation(
      id: id,
      title: title,
      modelId: json['modelId']?.toString() ?? '',
      createdAt: createdAt,
      updatedAt: DateTime.parse(json['updatedAt'].toString()),
      isArchived: json['isArchived'] as bool? ?? false,
      pendingRequestMessageId: json['pendingRequestMessageId']?.toString(),
      contextLimitTokens: json['contextLimitTokens'] as int? ?? 32768,
      usage: json['usage'] is Map
          ? ConversationUsage.fromJson(json['usage'] as Map)
          : null,
      pendingMemoryProposal: json['pendingMemoryProposal'] is Map
          ? PendingMemoryProposal.fromJson(json['pendingMemoryProposal'] as Map)
          : null,
      messages: (json['messages'] as List? ?? const [])
          .whereType<Map>()
          .map(ChatMessage.fromStorageJson)
          .toList(),
      sessionKey:
          json['sessionKey']?.toString() ??
          _legacySessionKey(createdAt, title, id),
      titleState: ConversationTitleState.values.byName(
        json['titleState']?.toString() ?? ConversationTitleState.manual.name,
      ),
      publicSourceWireBytesUsed: _wireBytes(json['publicSourceWireBytesUsed']),
      pendingToolProposal: json['pendingToolProposal'] is Map
          ? PendingToolProposal.fromJson(json['pendingToolProposal'] as Map)
          : null,
    );
  }
}

int _wireBytes(Object? value) {
  const limit = 8 * 1024 * 1024;
  if (value == null) return 0;
  if (value is! int || value < 0 || value > limit) return limit;
  return value;
}

String _legacySessionKey(DateTime createdAt, String title, String id) {
  final date =
      '${createdAt.year.toString().padLeft(4, '0')}-'
      '${createdAt.month.toString().padLeft(2, '0')}-'
      '${createdAt.day.toString().padLeft(2, '0')}';
  var safe = title
      .replaceAll(RegExp(r'[^\sa-zа-яё0-9]', caseSensitive: false), '_')
      .replaceAll(RegExp(r'[\s_]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (safe.length > 40) safe = safe.substring(0, 40);
  if (safe.isEmpty) safe = 'chat';
  final cleanId = id
      .replaceAll(RegExp(r'[^a-z0-9]', caseSensitive: false), '')
      .toLowerCase();
  final suffix = cleanId.isEmpty
      ? 'legacy'
      : (cleanId.length <= 10
            ? cleanId
            : cleanId.substring(cleanId.length - 10));
  return '${date}_${safe}_$suffix';
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
