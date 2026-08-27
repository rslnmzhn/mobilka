import '../domain/chat_message.dart';
import '../domain/chat_tool.dart';
import '../domain/pending_memory_proposal.dart';

abstract interface class ChatToolRuntime {
  Future<List<ChatToolDefinition>> availableTools(Set<String> allowedTools);

  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  });
}

class ChatToolExecutionContext {
  const ChatToolExecutionContext({
    required this.conversationId,
    required this.sessionKey,
  });

  final String conversationId;
  final String? sessionKey;
}

abstract interface class MemoryProposalRuntime {
  Future<PendingMemoryProposal?> prepareMemoryProposal(
    ChatToolCall call,
    String assistantMessageId,
    String? selectedAgentId,
    Set<String> allowedTools, [
    int callOccurrence = 0,
  ]);

  Future<void> revalidateMemoryProposal(PendingMemoryProposal proposal);

  Future<void> revalidateMemoryToolPermission({
    required String toolName,
    required String? selectedAgentId,
    required Set<String> allowedTools,
  });
}
