import 'chat_message.dart';
import 'chat_stream_event.dart';
import 'pending_memory_proposal.dart';
import 'pending_tool_proposal.dart';
import 'pending_skill_proposal.dart';
import 'request_execution_ledger.dart';
import 'pending_workspace_proposal.dart';

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
    this.pendingSkillProposal,
    this.requestExecutionLedger,
    this.pendingWorkspaceProposal,
    this.invalidPendingWorkspaceProposal = false,
    this.invalidWorkspaceToolCallId,
    this.invalidWorkspaceToolCallIndex,
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
  final PendingSkillProposal? pendingSkillProposal;
  final RequestExecutionLedger? requestExecutionLedger;
  final PendingWorkspaceProposal? pendingWorkspaceProposal;
  final bool invalidPendingWorkspaceProposal;
  final String? invalidWorkspaceToolCallId;
  final int? invalidWorkspaceToolCallIndex;

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
    PendingSkillProposal? pendingSkillProposal,
    bool clearPendingSkillProposal = false,
    RequestExecutionLedger? requestExecutionLedger,
    bool clearRequestExecutionLedger = false,
    PendingWorkspaceProposal? pendingWorkspaceProposal,
    bool clearPendingWorkspaceProposal = false,
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
    pendingSkillProposal: clearPendingSkillProposal
        ? null
        : (pendingSkillProposal ?? this.pendingSkillProposal),
    requestExecutionLedger: clearRequestExecutionLedger
        ? null
        : (requestExecutionLedger ?? this.requestExecutionLedger),
    pendingWorkspaceProposal: clearPendingWorkspaceProposal
        ? null
        : (pendingWorkspaceProposal ?? this.pendingWorkspaceProposal),
    invalidPendingWorkspaceProposal: clearPendingWorkspaceProposal
        ? false
        : invalidPendingWorkspaceProposal,
    invalidWorkspaceToolCallId: clearPendingWorkspaceProposal
        ? null
        : invalidWorkspaceToolCallId,
    invalidWorkspaceToolCallIndex: clearPendingWorkspaceProposal
        ? null
        : invalidWorkspaceToolCallIndex,
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
    'pendingSkillProposal': pendingSkillProposal?.toJson(),
    'requestExecutionLedger': requestExecutionLedger?.toJson(),
    'pendingWorkspaceProposal': pendingWorkspaceProposal?.toJson(),
    'messages': messages.map((message) => message.toStorageJson()).toList(),
  };

  factory Conversation.fromJson(Map<dynamic, dynamic> json) {
    final id = json['id'].toString();
    final rawTitle = json['title'];
    final hasValidTitle = rawTitle is String && rawTitle.trim().isNotEmpty;
    final title = hasValidTitle ? rawTitle : 'New conversation';
    final titleStateValue = json['titleState']?.toString();
    final createdAt = DateTime.parse(json['createdAt'].toString());
    final pendingRequestMessageId = json['pendingRequestMessageId']?.toString();
    final messages = (json['messages'] as List? ?? const [])
        .whereType<Map>()
        .map(ChatMessage.fromStorageJson)
        .toList();
    final sessionKey =
        json['sessionKey']?.toString() ??
        _legacySessionKey(createdAt, title, id);
    final rawWorkspaceProposal = json['pendingWorkspaceProposal'];
    final decodedWorkspaceProposal = rawWorkspaceProposal is Map
        ? PendingWorkspaceProposal.tryFromJson(rawWorkspaceProposal)
        : null;
    final workspaceProposal =
        decodedWorkspaceProposal != null &&
            _workspaceProposalBelongsToConversation(
              decodedWorkspaceProposal,
              conversationId: id,
              pendingRequestMessageId: pendingRequestMessageId,
              sessionKey: sessionKey,
              messages: messages,
            )
        ? decodedWorkspaceProposal
        : null;
    final invalidWorkspaceProposal =
        rawWorkspaceProposal != null && workspaceProposal == null;
    final invalidWorkspaceMarker = invalidWorkspaceProposal
        ? _workspaceProposalMarker(rawWorkspaceProposal)
        : null;
    return Conversation(
      id: id,
      title: title,
      modelId: json['modelId']?.toString() ?? '',
      createdAt: createdAt,
      updatedAt: DateTime.parse(json['updatedAt'].toString()),
      isArchived: json['isArchived'] as bool? ?? false,
      pendingRequestMessageId: pendingRequestMessageId,
      contextLimitTokens: json['contextLimitTokens'] as int? ?? 32768,
      usage: json['usage'] is Map
          ? ConversationUsage.fromJson(json['usage'] as Map)
          : null,
      pendingMemoryProposal: json['pendingMemoryProposal'] is Map
          ? PendingMemoryProposal.fromJson(json['pendingMemoryProposal'] as Map)
          : null,
      messages: messages,
      sessionKey: sessionKey,
      titleState: ConversationTitleState.values.byName(
        hasValidTitle
            ? (titleStateValue ?? ConversationTitleState.manual.name)
            : ConversationTitleState.fallback.name,
      ),
      publicSourceWireBytesUsed: _wireBytes(json['publicSourceWireBytesUsed']),
      pendingToolProposal: json['pendingToolProposal'] is Map
          ? PendingToolProposal.fromJson(json['pendingToolProposal'] as Map)
          : null,
      pendingSkillProposal: json['pendingSkillProposal'] is Map
          ? PendingSkillProposal.fromJson(json['pendingSkillProposal'] as Map)
          : null,
      requestExecutionLedger: json['requestExecutionLedger'] is Map
          ? RequestExecutionLedger.fromJson(
              json['requestExecutionLedger'] as Map,
            )
          : null,
      pendingWorkspaceProposal: workspaceProposal,
      invalidPendingWorkspaceProposal: invalidWorkspaceProposal,
      invalidWorkspaceToolCallId: invalidWorkspaceMarker?.toolCallId,
      invalidWorkspaceToolCallIndex: invalidWorkspaceMarker?.toolCallIndex,
    );
  }
}

bool workspaceProposalBelongsToConversation(
  PendingWorkspaceProposal proposal,
  Conversation conversation,
) => _workspaceProposalBelongsToConversation(
  proposal,
  conversationId: conversation.id,
  pendingRequestMessageId: conversation.pendingRequestMessageId,
  sessionKey: conversation.sessionKey,
  messages: conversation.messages,
);

bool _workspaceProposalBelongsToConversation(
  PendingWorkspaceProposal proposal, {
  required String conversationId,
  required String? pendingRequestMessageId,
  required String? sessionKey,
  required List<ChatMessage> messages,
}) {
  if (proposal.conversationId != conversationId ||
      proposal.requestId != pendingRequestMessageId ||
      proposal.sessionKey != sessionKey) {
    return false;
  }
  final assistants = messages.where(
    (message) => message.id == proposal.assistantMessageId,
  );
  if (assistants.length != 1) return false;
  final assistant = assistants.single;
  if (assistant.role != ChatRole.assistant ||
      (assistant.status != ChatMessageStatus.pending &&
          assistant.status != ChatMessageStatus.streaming) ||
      proposal.toolCallIndex >= assistant.toolCalls.length) {
    return false;
  }
  final call = assistant.toolCalls[proposal.toolCallIndex];
  if (call.id != proposal.toolCallId) return false;
  final occurrence = assistant.toolCalls
      .take(proposal.toolCallIndex)
      .where((candidate) => candidate.id == proposal.toolCallId)
      .length;
  return occurrence == proposal.callOccurrence;
}

String? _boundedString(Object? value) =>
    value is String && value.isNotEmpty && value.length <= 1024 ? value : null;

int? _nonNegativeInt(Object? value) =>
    value is int && value >= 0 ? value : null;

({String? toolCallId, int? toolCallIndex})? _workspaceProposalMarker(
  Object? source,
) {
  if (source is! Map) return null;
  final context = source['context'];
  final marker = context is Map ? context : source;
  return (
    toolCallId: _boundedString(marker['toolCallId']),
    toolCallIndex: _nonNegativeInt(marker['toolCallIndex']),
  );
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
