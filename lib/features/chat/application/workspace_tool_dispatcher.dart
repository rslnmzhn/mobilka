part of 'chat_tool_executor.dart';

extension ChatToolExecutorTestAccess on ChatToolExecutor {
  @visibleForTesting
  ChatToolExecutionContext publicSourceContextForTest(
    ChatStreamRequest request,
  ) => ChatToolExecutionContext(
    conversationId: request.conversationId,
    sessionKey: request.sessionKey,
    consumePublicSourceWireBytes: (bytes) => _consumeWireBytes(request, bytes),
    reservePublicSourceWireBytes: (maximum) =>
        _reserveWireBytes(request, maximum),
    refundPublicSourceWireBytes: (unused) => _refundWireBytes(request, unused),
  );
}

Future<bool> _dispatchWorkspaceTool({
  required ChatToolExecutor executor,
  required ChatStreamRequest request,
  required String assistantId,
  required ChatToolCall call,
  required int callIndex,
  required int occurrence,
  required _ToolExecutionState state,
}) async {
  final Object runtime = executor.runtime;
  final workspaceRuntime = runtime is WorkspaceProposalRuntime ? runtime : null;
  if (workspaceRuntime?.handlesWorkspaceMutation(call.name) != true) {
    return false;
  }
  try {
    state.workspaceProposal = await workspaceRuntime!.prepareWorkspaceProposal(
      call: call,
      context: state.context,
      requestId: request.requestMessageId,
      assistantMessageId: assistantId,
      selectedAgentId: request.selectedAgentId,
      allowedTools: request.allowedTools,
      callOccurrence: occurrence,
      toolCallIndex: callIndex,
    );
  } on FormatException catch (error) {
    state.addError(call, callIndex, error.message, executor);
  } on Object {
    state.addError(
      call,
      callIndex,
      ChatToolExecutor.unexpectedToolError,
      executor,
    );
  }
  return true;
}

class _ToolExecutionState {
  _ToolExecutionState({required this.context});

  final ChatToolExecutionContext context;
  final results = <ChatMessage>[];
  PendingMemoryProposal? memoryProposal;
  PendingToolProposal? toolProposal;
  PendingWorkspaceProposal? workspaceProposal;
  Object? get anyProposal =>
      memoryProposal ?? toolProposal ?? workspaceProposal;
  var budgetExceeded = false;

  void addError(
    ChatToolCall call,
    int callIndex,
    String message,
    ChatToolExecutor executor,
  ) {
    results.add(executor._toolErrorResult(call, callIndex, message));
  }
}
