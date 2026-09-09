import 'dart:io';

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/logging/app_logger.dart';
import '../../../features/memory/application/skills_chat_tools.dart';
import '../../../features/memory/application/workspace_paths.dart';
import '../../../features/memory/data/memory_repository.dart';
import '../../../features/memory/application/persona_chat_tools.dart';
import '../../artifacts/application/artifacts_chat_tool_runtime.dart';
import '../../chat/domain/chat_message.dart';
import '../../chat/domain/chat_tool.dart';
import '../../chat/domain/pending_memory_proposal.dart';
import '../../memory/application/memory_chat_tool_runtime.dart';
import '../../public_source/application/public_source_chat_tool_runtime.dart';
import '../../settings/data/settings_repository.dart';
import '../../web_search/application/web_search_chat_tool_runtime.dart';
import '../domain/pending_workspace_proposal.dart';
import 'chat_tool_runtime.dart';
import 'workspace_chat_tool_adapter.dart';
import 'document_tool_runtime.dart';
import 'document_proposal_chat_runtime.dart';
import 'session_document_snapshot_source.dart';
import '../../memory/application/session_workspace_boundary_adapter.dart';
import '../../workspace/application/session_workspace_boundary.dart';
import '../../documents/application/document_tool_service.dart';
import '../../documents/application/native_document_extractor.dart';
import '../../documents/data/android_document_worker_supervisor.dart';
import '../../documents/data/windows_document_worker_supervisor.dart';
import '../../documents/domain/document_worker_supervisor.dart';
import '../domain/pending_document_proposal.dart';

/// Merges every feature tool runtime into the single runtime consumed by the
/// streaming coordinator. A call is dispatched to the runtime that advertises
/// it for the current allowed-tools set; unknown tools keep failing with a
/// non-mutating error envelope.
///
/// Also forwards [MemoryProposalRuntime] so the coordinator can keep preparing
/// `update_memory_file` confirmable proposals through this composite.
final skillsChatToolsProvider = Provider<SkillsChatTools>(
  (ref) => SkillsChatTools(
    workspace: WorkspaceStore(repository: ref.watch(memoryRepositoryProvider)),
  ),
);

Future<DocumentToolService> _documentService() async {
  final DocumentWorkerSupervisor supervisor;
  if (Platform.isAndroid) {
    final value = AndroidDocumentWorkerSupervisor();
    await value.checkAvailability();
    supervisor = value;
  } else if (Platform.isWindows) {
    final value = WindowsDocumentWorkerSupervisor();
    await value.checkAvailability();
    supervisor = value;
  } else {
    return DocumentToolService();
  }
  return DocumentToolService(
    nativeExtractor: NativeDocumentExtractor(supervisor: supervisor),
    readyNativeOperations: DocumentWorkerOperation.values.toSet(),
  );
}

final class _PlatformDocumentRuntime
    implements ChatToolRuntime, DocumentProposalRuntime {
  _PlatformDocumentRuntime(this.source);
  final DocumentSnapshotSource source;
  DocumentProposalChatRuntime? _runtime;
  Future<DocumentProposalChatRuntime> _load() async =>
      _runtime ??= DocumentProposalChatRuntime(
        DocumentToolRuntime(service: await _documentService(), source: source),
      );
  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async => (await _load()).availableTools(allowedTools);
  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) async => (await _load()).executeTool(call, allowedTools, context: context);
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
  }) async => (await _load()).prepareDocumentProposal(
    call: call,
    context: context,
    requestId: requestId,
    assistantMessageId: assistantMessageId,
    selectedAgentId: selectedAgentId,
    allowedTools: allowedTools,
    callOccurrence: callOccurrence,
    toolCallIndex: toolCallIndex,
  );
  @override
  Future<String> confirmDocumentProposal({
    required PendingDocumentProposal proposal,
    required String claimToken,
    required ChatToolCall call,
    required ChatToolExecutionContext context,
    required String requestId,
    required String assistantMessageId,
    required String selectedAgentId,
    required Set<String> allowedTools,
    required int callOccurrence,
    required int toolCallIndex,
  }) async => (await _load()).confirmDocumentProposal(
    proposal: proposal,
    claimToken: claimToken,
    call: call,
    context: context,
    requestId: requestId,
    assistantMessageId: assistantMessageId,
    selectedAgentId: selectedAgentId,
    allowedTools: allowedTools,
    callOccurrence: callOccurrence,
    toolCallIndex: toolCallIndex,
  );
  @override
  String rejectDocumentProposal() => '{"error":"requires_confirmation"}';
}

final chatToolRuntimeRegistryProvider = Provider<CompositeChatToolRuntime>((
  ref,
) {
  return CompositeChatToolRuntime([
    RegisteredChatToolRuntime(
      'documents',
      () => _PlatformDocumentRuntime(
        SessionDocumentSnapshotSource(
          resolveBoundary: (context, sessionKey) {
            final binding = context.workspaceBinding;
            if (binding == null) {
              throw StateError('missing_document_workspace');
            }
            final boundary = MemorySessionWorkspaceBoundaryAdapter(
              ref.read(memoryRepositoryProvider),
            ).resolve(binding, sessionKey);
            if (boundary is! BinarySessionWorkspaceBoundary) {
              throw StateError('document_binary_source_unavailable');
            }
            return boundary;
          },
        ),
      ),
      failurePolicy: ChatToolRuntimeFailurePolicy.omitOnAvailabilityFailure,
    ),
    RegisteredChatToolRuntime(
      'artifacts',
      () => ref.read(artifactsChatToolRuntimeProvider),
    ),
    RegisteredChatToolRuntime(
      'skills',
      () => ref.read(skillsChatToolsProvider),
    ),
    RegisteredChatToolRuntime(
      'session_workspace',
      () => ref.read(workspaceChatToolRuntimeProvider),
    ),
    RegisteredChatToolRuntime(
      'personas',
      () => ref.read(personaChatToolsProvider),
    ),
    RegisteredChatToolRuntime(
      'memory',
      () => ref.read(memoryChatToolRuntimeProvider),
    ),
    RegisteredChatToolRuntime(
      'public_source',
      () => ref.read(publicSourceChatToolRuntimeProvider),
    ),
    RegisteredChatToolRuntime(
      'web_search',
      () => ref.read(webSearchChatToolRuntimeProvider),
      failurePolicy: ChatToolRuntimeFailurePolicy.omitOnAvailabilityFailure,
    ),
  ], logger: ref.watch(appLoggerProvider));
});

enum ChatToolRuntimeFailurePolicy { required, omitOnAvailabilityFailure }

class RegisteredChatToolRuntime {
  const RegisteredChatToolRuntime(
    this.id,
    this.create, {
    this.failurePolicy = ChatToolRuntimeFailurePolicy.required,
  });

  final String id;
  final ChatToolRuntime Function() create;
  final ChatToolRuntimeFailurePolicy failurePolicy;
}

class CompositeChatToolRuntime
    implements
        ChatToolRuntime,
        MemoryProposalRuntime,
        WorkspaceProposalRuntime,
        DocumentProposalRuntime {
  CompositeChatToolRuntime(Iterable<Object> runtimes, {AppLogger? logger})
    : _runtimes = [
        for (final (index, runtime) in runtimes.indexed)
          runtime is RegisteredChatToolRuntime
              ? runtime
              : RegisteredChatToolRuntime(
                  'legacy_$index',
                  () => runtime as ChatToolRuntime,
                ),
      ],
      _logger = logger ?? AppLogger();

  final List<RegisteredChatToolRuntime> _runtimes;
  final AppLogger _logger;

  MemoryProposalRuntime? get _proposalRuntime {
    for (final registration in _runtimes) {
      final runtime = registration.create();
      if (runtime is MemoryProposalRuntime) {
        return runtime as MemoryProposalRuntime;
      }
    }
    return null;
  }

  WorkspaceProposalRuntime? get _workspaceProposalRuntime {
    for (final registration in _runtimes) {
      try {
        final runtime = registration.create();
        if (runtime is WorkspaceProposalRuntime) {
          return runtime as WorkspaceProposalRuntime;
        }
      } on Object catch (error, stackTrace) {
        if (!_omitFailure(registration, error, stackTrace)) rethrow;
      }
    }
    return null;
  }

  DocumentProposalRuntime? get _documentProposalRuntime {
    for (final registration in _runtimes) {
      try {
        final runtime = registration.create();
        if (runtime is DocumentProposalRuntime) {
          return runtime as DocumentProposalRuntime;
        }
      } on Object catch (error, stackTrace) {
        if (!_omitFailure(registration, error, stackTrace)) rethrow;
      }
    }
    return null;
  }

  @override
  bool handlesDocumentRead(String toolName) =>
      _documentProposalRuntime?.handlesDocumentRead(toolName) ?? false;

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
  }) {
    final runtime = _documentProposalRuntime;
    if (runtime == null || !runtime.handlesDocumentRead(call.name)) {
      throw StateError('document_runtime_unavailable');
    }
    return runtime.prepareDocumentProposal(
      call: call,
      context: context,
      requestId: requestId,
      assistantMessageId: assistantMessageId,
      selectedAgentId: selectedAgentId,
      allowedTools: allowedTools,
      callOccurrence: callOccurrence,
      toolCallIndex: toolCallIndex,
    );
  }

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
  }) {
    final runtime = _documentProposalRuntime;
    if (runtime == null) throw StateError('document_runtime_unavailable');
    return runtime.confirmDocumentProposal(
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
  }

  @override
  String rejectDocumentProposal() {
    final runtime = _documentProposalRuntime;
    if (runtime == null) throw StateError('document_runtime_unavailable');
    return runtime.rejectDocumentProposal();
  }

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async {
    final definitions = <ChatToolDefinition>[];
    final seen = <String>{};
    for (final registration in _runtimes) {
      try {
        for (final definition in await registration.create().availableTools(
          allowedTools,
        )) {
          if (seen.add(definition.name)) {
            definitions.add(definition);
          }
        }
      } on Object catch (error, stackTrace) {
        if (!_omitFailure(registration, error, stackTrace)) rethrow;
      }
    }
    return definitions;
  }

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) async {
    for (final registration in _runtimes) {
      ChatToolRuntime runtime;
      List<ChatToolDefinition> advertised;
      try {
        runtime = registration.create();
        advertised = await runtime.availableTools(allowedTools);
      } on Object catch (error, stackTrace) {
        if (!_omitFailure(registration, error, stackTrace)) rethrow;
        continue;
      }
      if (advertised.any((definition) => definition.name == call.name)) {
        return runtime.executeTool(call, allowedTools, context: context);
      }
    }
    return jsonEncode({'ok': false, 'error_code': 'unknown_tool'});
  }

  bool _omitFailure(
    RegisteredChatToolRuntime registration,
    Object error,
    StackTrace stackTrace,
  ) {
    if (registration.failurePolicy !=
        ChatToolRuntimeFailurePolicy.omitOnAvailabilityFailure) {
      return false;
    }
    _logger.log(
      event: 'chat.tool_availability',
      level: AppLogLevel.warning,
      runtimeId: registration.id,
      status: 'omitted',
      phase: 'runtime_availability',
      error: error,
      errorCode: switch (error) {
        UnsupportedError() => 'unsupported_operation',
        SettingsSecretUnavailableException() => 'secure_storage_unavailable',
        DioException() => 'network_error',
        FormatException() => 'invalid_data',
        _ => 'unexpected_error',
      },
      stackTrace: stackTrace,
    );
    return true;
  }

  @override
  Future<PendingMemoryProposal?> prepareMemoryProposal(
    ChatToolCall call,
    String assistantMessageId,
    String? selectedAgentId,
    Set<String> allowedTools, [
    int callOccurrence = 0,
  ]) {
    final runtime = _proposalRuntime;
    if (runtime == null) {
      throw StateError('Memory proposal runtime is unavailable.');
    }
    return runtime.prepareMemoryProposal(
      call,
      assistantMessageId,
      selectedAgentId,
      allowedTools,
      callOccurrence,
    );
  }

  @override
  Future<void> revalidateMemoryProposal(PendingMemoryProposal proposal) {
    final runtime = _proposalRuntime;
    if (runtime == null) {
      throw StateError('Memory proposal runtime is unavailable.');
    }
    return runtime.revalidateMemoryProposal(proposal);
  }

  @override
  Future<void> revalidateMemoryToolPermission({
    required String toolName,
    required String? selectedAgentId,
    required Set<String> allowedTools,
  }) {
    final runtime = _proposalRuntime;
    if (runtime == null) {
      throw StateError('Memory permission runtime is unavailable.');
    }
    return runtime.revalidateMemoryToolPermission(
      toolName: toolName,
      selectedAgentId: selectedAgentId,
      allowedTools: allowedTools,
    );
  }

  @override
  bool handlesWorkspaceMutation(String toolName) =>
      _workspaceProposalRuntime?.handlesWorkspaceMutation(toolName) ?? false;

  @override
  Future<PendingWorkspaceProposal> prepareWorkspaceProposal({
    required ChatToolCall call,
    required ChatToolExecutionContext context,
    required String requestId,
    required String assistantMessageId,
    required String? selectedAgentId,
    required Set<String> allowedTools,
    required int callOccurrence,
    required int toolCallIndex,
  }) {
    final runtime = _workspaceProposalRuntime;
    if (runtime == null) {
      throw StateError('Workspace proposal runtime unavailable');
    }
    return runtime.prepareWorkspaceProposal(
      call: call,
      context: context,
      requestId: requestId,
      assistantMessageId: assistantMessageId,
      selectedAgentId: selectedAgentId,
      allowedTools: allowedTools,
      callOccurrence: callOccurrence,
      toolCallIndex: toolCallIndex,
    );
  }

  @override
  Future<void> revalidateWorkspacePermission({
    required PendingWorkspaceProposal proposal,
    required String? selectedAgentId,
    required Set<String> allowedTools,
  }) {
    final runtime = _workspaceProposalRuntime;
    if (runtime == null) {
      throw StateError('Workspace proposal runtime unavailable');
    }
    return runtime.revalidateWorkspacePermission(
      proposal: proposal,
      selectedAgentId: selectedAgentId,
      allowedTools: allowedTools,
    );
  }
}
