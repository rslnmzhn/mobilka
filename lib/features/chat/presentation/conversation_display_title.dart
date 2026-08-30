import 'package:easy_localization/easy_localization.dart';

import '../domain/conversation.dart';

String conversationDisplayTitle(Conversation conversation) {
  final title = conversation.title.trim();
  final automaticPlaceholder =
      conversation.titleState == ConversationTitleState.pendingAutomatic ||
      conversation.titleState == ConversationTitleState.fallback;
  final legacyPlaceholder =
      conversation.titleState != ConversationTitleState.manual &&
      title == 'New conversation';
  if (title.isEmpty || automaticPlaceholder || legacyPlaceholder) {
    return 'chat.newConversation'.tr();
  }
  return conversation.title;
}
