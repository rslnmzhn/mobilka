import '../domain/chat_message.dart';
import '../domain/chat_tool.dart';
import '../domain/pending_memory_proposal.dart';
import '../../memory/application/workspace_paths.dart';

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
    this.workspaceBinding,
    this.cancellation,
    this.consumePublicSourceWireBytes,
    this.reservePublicSourceWireBytes,
    this.refundPublicSourceWireBytes,
  });

  final String conversationId;
  final String? sessionKey;
  final WorkspaceBinding? workspaceBinding;
  final ChatToolCancellation? cancellation;
  final Future<void> Function(int bytes)? consumePublicSourceWireBytes;
  final Future<int> Function(int maximum)? reservePublicSourceWireBytes;
  final Future<void> Function(int unused)? refundPublicSourceWireBytes;
}

abstract interface class ChatToolCancellation {
  bool get isCancelled;
  Future<void> get whenCancelled;
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
