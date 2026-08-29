import '../domain/chat_message.dart';
import '../domain/chat_tool.dart';
import '../domain/pending_memory_proposal.dart';
import '../../memory/application/workspace_paths.dart';
import '../domain/pending_skill_proposal.dart';
import 'request_tool_security_state.dart';

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
    this.skillReflection,
  });

  final String conversationId;
  final String? sessionKey;
  final WorkspaceBinding? workspaceBinding;
  final ChatToolCancellation? cancellation;
  final Future<void> Function(int bytes)? consumePublicSourceWireBytes;
  final Future<int> Function(int maximum)? reservePublicSourceWireBytes;
  final Future<void> Function(int unused)? refundPublicSourceWireBytes;
  final SkillReflectionToolContext? skillReflection;
}

class SkillReflectionToolContext {
  SkillReflectionToolContext({
    required this.conversationId,
    required this.requestId,
    required this.assistantMessageId,
    required this.provenance,
    required this.permissionSnapshot,
    required this.workspaceBindingSnapshot,
    required this.selectedAgentId,
    required this.persistProposal,
  });

  final String conversationId;
  final String requestId;
  final String assistantMessageId;
  final SkillLearningProvenance provenance;
  bool get sourceDerived => provenance.sourceDerived;
  final String? permissionSnapshot;
  final WorkspaceBindingSnapshot workspaceBindingSnapshot;
  final String? selectedAgentId;
  final Future<bool> Function(PendingSkillProposal proposal) persistProposal;
  bool listed = false;
  final Set<String> readNames = {};
  bool proposed = false;
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
