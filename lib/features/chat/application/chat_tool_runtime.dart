import '../domain/chat_message.dart';
import '../domain/chat_tool.dart';
import '../domain/pending_memory_proposal.dart';

abstract interface class ChatToolRuntime {
  Future<List<ChatToolDefinition>> availableTools(Set<String> allowedTools);

  Future<String> executeTool(ChatToolCall call, Set<String> allowedTools);
}

abstract interface class MemoryProposalRuntime {
  Future<PendingMemoryProposal?> prepareMemoryProposal(
    ChatToolCall call,
    String assistantMessageId,
    String? selectedAgentId,
    Set<String> allowedTools,
  );

  Future<void> revalidateMemoryProposal(PendingMemoryProposal proposal);
}
