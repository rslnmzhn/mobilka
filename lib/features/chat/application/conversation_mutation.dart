import '../domain/conversation.dart';

typedef ConversationMutation = Conversation? Function(Conversation latest);
typedef PersistConversationMutation =
    Future<Conversation?> Function(
      String conversationId,
      ConversationMutation mutation,
    );
