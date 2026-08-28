import '../../models/domain/model_capabilities.dart';
import '../../memory/application/workspace_paths.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import 'chat_stream_request.dart';

class SendAgainPreparation {
  const SendAgainPreparation({
    required this.requestId,
    required this.assistantId,
    required this.mutation,
  });

  final String requestId;
  final String assistantId;
  final Conversation? Function(Conversation latest) mutation;
}

class SendAgainService {
  const SendAgainService();

  SendAgainPreparation prepare({
    required String messageId,
    required DateTime now,
    required void Function() onInvalid,
    required void Function() onAttachmentsFiltered,
  }) {
    final requestId = '${now.microsecondsSinceEpoch}-user';
    final assistantId = '${now.microsecondsSinceEpoch}-assistant';
    return SendAgainPreparation(
      requestId: requestId,
      assistantId: assistantId,
      mutation: (latest) {
        final original = latest.messages
            .where((message) => message.id == messageId)
            .firstOrNull;
        if (original == null ||
            original.role != ChatRole.user ||
            original.content.trim().isEmpty) {
          onInvalid();
          return null;
        }
        final attachments = filterAttachmentsForModel(
          original.attachments,
          visionSupported: ModelCapabilityResolver.resolve(
            latest.modelId,
          ).vision,
        );
        if (attachments.length != original.attachments.length) {
          onAttachmentsFiltered();
        }
        return latest.copyWith(
          updatedAt: now,
          pendingRequestMessageId: requestId,
          messages: [
            ...latest.messages,
            ChatMessage(
              id: requestId,
              role: ChatRole.user,
              content: original.content,
              createdAt: now,
              attachments: List.unmodifiable(attachments),
            ),
            ChatMessage(
              id: assistantId,
              role: ChatRole.assistant,
              content: '',
              createdAt: now,
              status: ChatMessageStatus.pending,
            ),
          ],
        );
      },
    );
  }

  ChatStreamRequest request({
    required Conversation conversation,
    required SendAgainPreparation preparation,
    required String? selectedAgentId,
    required Set<String> allowedTools,
    required WorkspaceBinding? workspaceBinding,
  }) => buildChatStreamRequest(
    conversation,
    preparation.requestId,
    preparation.assistantId,
    selectedAgentId: selectedAgentId,
    allowedTools: allowedTools,
    workspaceBinding: workspaceBinding,
  );
}
