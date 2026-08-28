import 'dart:convert';

import '../domain/chat_message.dart';
import '../domain/chat_tool.dart';

ChatToolEffect resolveChatToolEffect(
  ChatToolDefinition? definition,
  ChatToolCall call,
) {
  if (call.name == 'update_memory_file') {
    try {
      final arguments = jsonDecode(call.arguments);
      if (arguments is Map && arguments['file_name'] == 'memory.md') {
        return ChatToolEffect.mutating;
      }
    } on FormatException {
      return ChatToolEffect.sensitive;
    }
  }
  return definition?.effect ?? ChatToolEffect.sensitive;
}
