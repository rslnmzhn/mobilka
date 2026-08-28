import 'conversation_mutation.dart';
import 'chat_stream_request.dart';
import '../domain/chat_message.dart';

class ChatStreamFinalizer {
  const ChatStreamFinalizer({
    required this.persistMutation,
    required this.publishError,
  });

  final PersistConversationMutation persistMutation;
  final void Function(String message) publishError;

  Future<void> interrupt(ChatStreamRequest request, String message) async {
    await finish(request, ChatMessageStatus.interrupted);
    publishError(message);
  }

  Future<bool> finish(
    ChatStreamRequest request,
    ChatMessageStatus status,
  ) async {
    final updated = await persistMutation(request.conversationId, (latest) {
      if (latest.pendingRequestMessageId != request.requestMessageId) {
        return null;
      }
      return latest.copyWith(
        updatedAt: DateTime.now(),
        clearPendingRequest: status == ChatMessageStatus.complete,
        messages: latest.messages
            .map(
              (message) =>
                  message.role == ChatRole.assistant &&
                      (message.status == ChatMessageStatus.pending ||
                          message.status == ChatMessageStatus.streaming)
                  ? message.copyWith(status: status)
                  : message,
            )
            .toList(),
      );
    });
    return updated != null;
  }
}
