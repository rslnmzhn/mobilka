import '../domain/chat_message.dart';
import '../domain/conversation.dart';

class ChatState {
  const ChatState({
    required this.conversations,
    this.activeConversationId,
    this.errorMessage,
    this.query = '',
    this.showArchived = false,
    this.confirmingMemoryToolCallId,
    this.confirmingToolCallId,
    this.confirmingSkillName,
  });

  final List<Conversation> conversations;
  final String? activeConversationId;
  final String? errorMessage;
  final String query;
  final bool showArchived;
  final String? confirmingMemoryToolCallId;
  final String? confirmingToolCallId;
  final String? confirmingSkillName;

  Conversation? get activeConversation =>
      conversationById(activeConversationId);

  bool get isStreaming => activeConversation?.isStreaming ?? false;

  bool get hasInFlightRequest => conversations.any(
    (item) =>
        item.isStreaming ||
        item.pendingMemoryProposal != null ||
        item.pendingToolProposal != null,
  );

  List<Conversation> get visibleConversations => conversations
      .where((item) => item.isArchived == showArchived)
      .where((item) => item.title.toLowerCase().contains(query.toLowerCase()))
      .toList();

  Conversation? conversationById(String? id) =>
      conversations.where((item) => item.id == id).firstOrNull;

  ChatState copyWith({
    List<Conversation>? conversations,
    String? activeConversationId,
    bool clearActiveConversation = false,
    String? errorMessage,
    bool clearError = false,
    String? query,
    bool? showArchived,
    String? confirmingMemoryToolCallId,
    bool clearConfirmingMemory = false,
    String? confirmingToolCallId,
    bool clearConfirmingTool = false,
    String? confirmingSkillName,
    bool clearConfirmingSkill = false,
  }) => ChatState(
    conversations: conversations ?? this.conversations,
    activeConversationId: clearActiveConversation
        ? null
        : (activeConversationId ?? this.activeConversationId),
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    query: query ?? this.query,
    showArchived: showArchived ?? this.showArchived,
    confirmingMemoryToolCallId: clearConfirmingMemory
        ? null
        : (confirmingMemoryToolCallId ?? this.confirmingMemoryToolCallId),
    confirmingToolCallId: clearConfirmingTool
        ? null
        : (confirmingToolCallId ?? this.confirmingToolCallId),
    confirmingSkillName: clearConfirmingSkill
        ? null
        : (confirmingSkillName ?? this.confirmingSkillName),
  );
}

extension ConversationStreamingState on Conversation {
  bool get isStreaming => messages.any(
    (message) =>
        message.status == ChatMessageStatus.pending ||
        message.status == ChatMessageStatus.streaming,
  );
}
