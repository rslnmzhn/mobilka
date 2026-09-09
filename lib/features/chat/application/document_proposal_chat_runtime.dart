import '../domain/chat_message.dart';
import '../domain/chat_tool.dart';
import '../domain/pending_document_proposal.dart';
import 'chat_tool_runtime.dart';
import 'document_disclosure_service.dart';
import 'document_tool_runtime.dart';

final class DocumentProposalChatRuntime
    implements ChatToolRuntime, DocumentProposalRuntime {
  DocumentProposalChatRuntime(DocumentToolRuntime runtime)
    : _runtime = runtime,
      _disclosure = DocumentDisclosureService(runtime: runtime);

  final DocumentToolRuntime _runtime;
  final DocumentDisclosureService _disclosure;

  @override
  Future<List<ChatToolDefinition>> availableTools(Set<String> allowedTools) =>
      _runtime.availableTools(allowedTools);

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) => _runtime.executeTool(call, allowedTools, context: context);

  @override
  bool handlesDocumentRead(String toolName) =>
      toolName == 'extract_document' || toolName == 'ocr_document';

  @override
  Future<PendingDocumentProposal> prepareDocumentProposal({
    required ChatToolCall call,
    required ChatToolExecutionContext context,
    required String requestId,
    required String assistantMessageId,
    required String selectedAgentId,
    required Set<String> allowedTools,
    required int callOccurrence,
    required int toolCallIndex,
  }) => _disclosure.prepare(
    call: call,
    context: context,
    requestId: requestId,
    assistantMessageId: assistantMessageId,
    toolCallIndex: toolCallIndex,
    callOccurrence: callOccurrence,
    selectedAgentId: selectedAgentId,
    allowedTools: allowedTools,
  );

  @override
  Future<String> confirmDocumentProposal({
    required PendingDocumentProposal proposal,
    required String claimToken,
    required ChatToolCall call,
    required ChatToolExecutionContext context,
    required String requestId,
    required String assistantMessageId,
    required int toolCallIndex,
    required int callOccurrence,
    required String selectedAgentId,
    required Set<String> allowedTools,
  }) => _disclosure.confirm(
    proposal: proposal,
    claimToken: claimToken,
    call: call,
    context: context,
    requestId: requestId,
    assistantMessageId: assistantMessageId,
    toolCallIndex: toolCallIndex,
    callOccurrence: callOccurrence,
    selectedAgentId: selectedAgentId,
    allowedTools: allowedTools,
  );

  @override
  String rejectDocumentProposal() => _disclosure.reject();
}
