import '../domain/chat_message.dart';
import '../domain/conversation.dart';

class ChatStreamRequest {
  ChatStreamRequest({
    required this.conversationId,
    required this.requestMessageId,
    required this.assistantMessageId,
    required this.modelId,
    required this.history,
    required this.selectedAgentId,
    required Set<String> allowedTools,
    this.conversationTitle = 'mobilka',
  }) : allowedTools = Set.unmodifiable(allowedTools);

  final String conversationId;
  final String requestMessageId;
  final String assistantMessageId;
  final String modelId;
  final List<ChatMessage> history;
  final String? selectedAgentId;
  final Set<String> allowedTools;

  /// Shown on the Android foreground-service notification.
  final String conversationTitle;
}

({Conversation conversation, ChatStreamRequest request})?
prepareInterruptedRetry(
  Conversation conversation,
  DateTime now, {
  required String? selectedAgentId,
  required Set<String> allowedTools,
}) {
  final requestId = conversation.pendingRequestMessageId;
  if (requestId == null) return null;
  final requestMessage = conversation.messages
      .where((message) => message.id == requestId)
      .firstOrNull;
  if (requestMessage == null || requestMessage.role != ChatRole.user) {
    return null;
  }

  final assistantId = '${now.microsecondsSinceEpoch}-assistant';
  final updated = conversation.copyWith(
    updatedAt: now,
    messages: [
      ...conversation.messages,
      ChatMessage(
        id: assistantId,
        role: ChatRole.assistant,
        content: '',
        createdAt: now,
        status: ChatMessageStatus.pending,
      ),
    ],
  );
  return (
    conversation: updated,
    request: buildChatStreamRequest(
      updated,
      requestId,
      assistantId,
      selectedAgentId: selectedAgentId,
      allowedTools: allowedTools,
    ),
  );
}

ChatStreamRequest buildChatStreamRequest(
  Conversation conversation,
  String requestId,
  String assistantId, {
  required String? selectedAgentId,
  required Set<String> allowedTools,
}) => ChatStreamRequest(
  conversationId: conversation.id,
  requestMessageId: requestId,
  assistantMessageId: assistantId,
  modelId: conversation.modelId,
  conversationTitle: conversation.title,
  selectedAgentId: selectedAgentId,
  allowedTools: allowedTools,
  history: conversation.messages
      .where((message) => message.id != assistantId)
      .where(
        (message) =>
            message.role != ChatRole.assistant ||
            (message.status != ChatMessageStatus.interrupted &&
                message.status != ChatMessageStatus.failed),
      )
      .toList(growable: false),
);
