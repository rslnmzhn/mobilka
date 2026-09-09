part of 'chat_tool_executor.dart';

final _documentProposals = Expando<PendingDocumentProposal>();

const deferredPendingDocumentConfirmation =
    '{"error":"deferred_pending_confirmation"}';

PendingDocumentProposal? _documentProposal(_ToolExecutionState state) =>
    _documentProposals[state];

void _deferCallsAfterDocumentProposal({
  required ChatToolExecutor executor,
  required List<ChatToolCall> calls,
  required int selectedIndex,
  required _ToolExecutionState state,
}) {
  for (var index = selectedIndex + 1; index < calls.length; index++) {
    state.results.add(
      executor._toolResult(
        calls[index],
        deferredPendingDocumentConfirmation,
        index,
      ),
    );
  }
}

Future<bool> _dispatchDocumentTool({
  required ChatToolExecutor executor,
  required ChatStreamRequest request,
  required String assistantId,
  required ChatToolCall call,
  required int callIndex,
  required int occurrence,
  required _ToolExecutionState state,
}) async {
  final runtime = executor.runtime;
  if (runtime is! DocumentProposalRuntime) {
    return false;
  }
  final documentRuntime = runtime as DocumentProposalRuntime;
  if (!documentRuntime.handlesDocumentRead(call.name)) {
    return false;
  }
  final selectedAgentId = request.selectedAgentId;
  if (selectedAgentId == null) {
    state.addError(call, callIndex, 'document_agent_unavailable', executor);
    return true;
  }
  try {
    _documentProposals[state] = await documentRuntime.prepareDocumentProposal(
      call: call,
      context: state.context,
      requestId: request.requestMessageId,
      assistantMessageId: assistantId,
      selectedAgentId: selectedAgentId,
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
