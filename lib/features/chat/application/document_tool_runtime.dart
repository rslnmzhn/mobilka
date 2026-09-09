import 'dart:convert';

import '../../documents/application/document_tool_service.dart';
import '../../documents/domain/document_limits.dart';
import '../../documents/domain/document_snapshot.dart';
import '../../documents/domain/document_tool_request.dart';
import '../../documents/domain/document_worker_supervisor.dart';
import '../domain/chat_message.dart';
import '../domain/chat_tool.dart';
import 'chat_tool_runtime.dart';
import 'document_tool_definitions.dart';

abstract interface class DocumentSnapshotSource {
  Set<DocumentToolInputFormat> get supportedFormats;

  Future<DocumentSnapshot> capture({
    required DocumentToolRequest request,
    required ChatToolExecutionContext context,
    required String requestId,
  });
}

final class DocumentToolRuntime implements ChatToolRuntime {
  DocumentToolRuntime({DocumentToolService? service, this.source})
    : service = service ?? DocumentToolService();

  final DocumentToolService service;
  final DocumentSnapshotSource? source;

  static const requiresConfirmation = '{"error":"requires_confirmation"}';

  bool _supports(
    DocumentToolOperation operation,
    DocumentToolInputFormat format,
  ) {
    if (source?.supportedFormats.contains(format) != true) return false;
    return switch ((operation, format)) {
      (DocumentToolOperation.extract, DocumentToolInputFormat.csv) ||
      (DocumentToolOperation.extract, DocumentToolInputFormat.docx) ||
      (DocumentToolOperation.extract, DocumentToolInputFormat.xlsx) => true,
      (DocumentToolOperation.extract, DocumentToolInputFormat.pdf) =>
        service.supportsNative(DocumentWorkerOperation.pdfText),
      (DocumentToolOperation.ocr, DocumentToolInputFormat.pdf) =>
        service.supportsNative(DocumentWorkerOperation.pdfOcr),
      (DocumentToolOperation.ocr, DocumentToolInputFormat.png) ||
      (
        DocumentToolOperation.ocr,
        DocumentToolInputFormat.jpeg,
      ) => service.supportsNative(DocumentWorkerOperation.imageOcr),
      _ => false,
    };
  }

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async {
    final tools = <ChatToolDefinition>[];
    for (final definition in documentToolDefinitions) {
      if (!allowedTools.contains(definition.name)) continue;
      final operation = definition.name == 'extract_document'
          ? DocumentToolOperation.extract
          : DocumentToolOperation.ocr;
      final formats = DocumentToolInputFormat.values
          .where((format) => _supports(operation, format))
          .map((format) => format.name)
          .toList(growable: false);
      if (formats.isEmpty) continue;
      final parameters = Map<String, dynamic>.from(definition.parameters);
      final properties = Map<String, dynamic>.from(
        parameters['properties'] as Map,
      );
      properties['format'] = {'type': 'string', 'enum': formats};
      parameters['properties'] = properties;
      tools.add(
        ChatToolDefinition(
          name: definition.name,
          description: definition.description,
          parameters: parameters,
          effect: ChatToolEffect.runtimeConfirmed,
        ),
      );
    }
    return tools;
  }

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) async => requiresConfirmation;

  Future<LocalDocumentToolResult> prepareLocalResult({
    required ChatToolCall call,
    required Set<String> allowedTools,
    required ChatToolExecutionContext context,
    required String requestId,
  }) async {
    if (!allowedTools.contains(call.name)) {
      throw const DocumentException('document_permission_denied');
    }
    final request = DocumentToolRequest.parse(call.name, call.arguments);
    final source = this.source;
    if (source == null || !_supports(request.operation, request.format)) {
      throw const DocumentException('document_source_unavailable');
    }
    final binding = context.workspaceBinding;
    if (binding == null || context.sessionKey == null || requestId.isEmpty) {
      throw const DocumentException('document_context_unavailable');
    }
    await binding.revalidateAccess();
    final bindingIdentity = jsonEncode(binding.snapshot.toJson());
    final snapshot = await source.capture(
      request: request,
      context: context,
      requestId: requestId,
    );
    await binding.revalidateAccess();
    if (snapshot.conversationId != context.conversationId ||
        snapshot.requestId != requestId ||
        snapshot.sessionKey != context.sessionKey ||
        jsonEncode(snapshot.binding.toJson()) != bindingIdentity ||
        jsonEncode(binding.snapshot.toJson()) != bindingIdentity) {
      throw const DocumentException('document_source_owner_mismatch');
    }
    request.validateSnapshot(snapshot);
    return service.execute(request, snapshot: snapshot);
  }
}
