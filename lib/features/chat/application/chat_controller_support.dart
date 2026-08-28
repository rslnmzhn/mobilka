import '../data/chat_repository.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import '../../memory/application/workspace_paths.dart';
import 'chat_stream_request.dart';

Conversation createNewConversation(String modelId, DateTime now) {
  final id = now.microsecondsSinceEpoch.toString();
  const title = 'New conversation';
  return Conversation(
    id: id,
    title: title,
    modelId: modelId,
    createdAt: now,
    updatedAt: now,
    messages: const [],
    titleState: ConversationTitleState.pendingAutomatic,
    sessionKey: WorkspaceStore.sessionKey(
      createdAt: now,
      title: title,
      conversationId: id,
    ),
  );
}

WorkspaceBinding? retryWorkspaceBinding({
  required Conversation conversation,
  required WorkspaceBinding? retained,
  required WorkspaceBinding? Function() captureCurrent,
}) {
  if (retained != null) return retained;
  final requestIndex = conversation.messages.indexWhere(
    (message) => message.id == conversation.pendingRequestMessageId,
  );
  final followedMemoryDecision = conversation.messages
      .skip(requestIndex < 0 ? conversation.messages.length : requestIndex + 1)
      .any(
        (message) => message.toolCalls.any(
          (call) => const {
            'update_memory_file',
            'save_persona',
            'delete_persona',
          }.contains(call.name),
        ),
      );
  return followedMemoryDecision ? null : captureCurrent();
}

class AutomaticTitleStarter {
  const AutomaticTitleStarter({
    required this.repository,
    required this.claim,
    required this.complete,
  });

  final ChatRepository repository;
  final Future<Conversation?> Function(String id) claim;
  final Future<void> Function(String id, String title) complete;

  void start(ChatStreamRequest request, String assistantText) {
    Future<void>(() async {
      try {
        final conversation = await claim(request.conversationId);
        final firstUser = conversation?.messages
            .where((message) => message.role == ChatRole.user)
            .firstOrNull;
        if (firstUser == null) return;
        final generated = await repository.createAutomaticTitle(
          model: request.modelId,
          firstUserText: firstUser.content,
          assistantText: assistantText,
        );
        await complete(request.conversationId, generated);
      } on Object {
        return;
      }
    });
  }
}
