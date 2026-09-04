import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agents_controller.dart';
import '../domain/chat_message.dart';
import '../domain/chat_tool.dart';
import '../../workspace/data/workspace_recovery_journal.dart';
import '../domain/pending_workspace_proposal.dart';
import '../../workspace/domain/session_workspace_path.dart';
import '../../workspace/domain/workspace_models.dart';
import '../../workspace/application/session_workspace_authority.dart';
import '../../workspace/application/session_workspace_boundary.dart';
import '../../workspace/application/unified_patch.dart';
import '../../workspace/application/workspace_mutation_coordinator.dart';
import '../../workspace/application/workspace_tool_helpers.dart';
import '../../memory/data/memory_repository.dart';
import 'chat_tool_runtime.dart';
import 'chat_workspace_boundary_factory.dart';
import 'workspace_read_executor.dart';
import 'workspace_tool_arguments.dart';
import 'workspace_tool_definitions.dart';

final workspaceChatToolRuntimeProvider = Provider<WorkspaceChatToolRuntime>((
  ref,
) {
  return WorkspaceChatToolRuntime(
    memoryRepository: ref.read(memoryRepositoryProvider),
    agentTools: (id) async {
      final catalog = await ref.read(agentsControllerProvider.future);
      return catalog.agents
          .where((item) => item.definition.id == id)
          .firstOrNull
          ?.definition
          .tools
          .toSet();
    },
  );
});

final class WorkspaceChatToolRuntime
    implements ChatToolRuntime, WorkspaceProposalRuntime {
  WorkspaceChatToolRuntime({
    required Future<Set<String>?> Function(String id) agentTools,
    MemoryRepository? memoryRepository,
  }) : _agentTools = agentTools,
       _memoryRepository = memoryRepository;

  final Future<Set<String>?> Function(String id) _agentTools;
  final MemoryRepository? _memoryRepository;

  static const definitions = workspaceToolDefinitions;

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async =>
      definitions.where((item) => allowedTools.contains(item.name)).toList();

  @override
  bool handlesWorkspaceMutation(String toolName) =>
      workspaceMutationTools.contains(toolName) ||
      toolName == 'write_session_notes';

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) async {
    _requireAllowed(call.name, allowedTools);
    if (handlesWorkspaceMutation(call.name)) {
      throw const FormatException('workspace_mutation_requires_confirmation');
    }
    return executeWorkspaceRead(
      call: call,
      authority: await _authority(context, requestId: 'read'),
      context: context,
    );
  }

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
  }) async {
    _requireAllowed(call.name, allowedTools);
    if (selectedAgentId == null) throw const FormatException('agent_required');
    final authority = await _authority(context, requestId: requestId);
    final args = parseWorkspaceArguments(call.arguments);
    final operation = call.name == 'write_session_notes'
        ? 'write_file'
        : call.name;
    if (call.name == 'write_session_notes') {
      requireWorkspaceKeys(args, required: const {'content'});
      args['path'] = 'session.md';
    }
    switch (operation) {
      case 'write_file':
        requireWorkspaceKeys(args, required: const {'path', 'content'});
      case 'apply_patch':
        requireWorkspaceKeys(args, required: const {'path', 'patch'});
      case 'move_file':
        requireWorkspaceKeys(args, required: const {'source', 'destination'});
      case 'delete_file':
      case 'make_directory':
        requireWorkspaceKeys(args, required: const {'path'});
      default:
        throw const FormatException('unknown_workspace_mutation');
    }
    final path = _proposalPath(operation, args);
    final destination = operation == 'move_file'
        ? requiredWorkspaceString(args, 'destination')
        : null;
    SessionWorkspacePath.parse(path);
    if (destination != null) SessionWorkspacePath.parse(destination);
    final source = await authority.metadata(path);
    final target = destination == null
        ? source
        : await authority.metadata(destination);
    String? content;
    String? patch;
    String preview;
    if ((operation == 'move_file' || operation == 'delete_file') &&
        source?.type != WorkspaceEntryType.file) {
      throw const FormatException('source_file_required');
    }
    if ((operation == 'write_file' || operation == 'make_directory') &&
        source?.type == WorkspaceEntryType.directory) {
      throw const FormatException('target_directory_conflict');
    }
    if (operation == 'make_directory' && source != null) {
      throw const FormatException('target_exists');
    }
    if (operation == 'write_file') {
      content = requiredWorkspaceString(
        args,
        'content',
        maxBytes: workspaceMaxTextBytes,
      );
      encodeWorkspaceText(content);
      preview = _preview(path, source, content);
    } else if (operation == 'apply_patch') {
      if (source?.type != WorkspaceEntryType.file) {
        throw const FormatException('source_file_required');
      }
      patch = requiredWorkspaceString(
        args,
        'patch',
        maxBytes: workspaceMaxPatchBytes,
      );
      final current = await authority.readEntireFile(path);
      content = UnifiedPatch.parse(patch, path).apply(current.content);
      preview = patch;
    } else {
      preview = operation == 'move_file'
          ? '$path -> $destination'
          : operation == 'delete_file'
          ? _deletePreview(path, await authority.readEntireFile(path))
          : '$operation $path';
    }
    final now = DateTime.now().toUtc();
    final rootIdentity = await authority.locked(
      (boundary) => boundary.rootIdentity(),
    );
    return PendingWorkspaceProposal(
      conversationId: context.conversationId,
      requestId: requestId,
      assistantMessageId: assistantMessageId,
      toolCallId: call.id,
      callOccurrence: callOccurrence,
      toolCallIndex: toolCallIndex,
      operation: operation,
      path: path,
      destination: destination,
      proposedContent: content,
      proposedContentHash: content == null
          ? null
          : workspaceHash(utf8.encode(content)),
      patch: patch,
      preview: preview,
      previewHash: workspaceHash(utf8.encode(preview)),
      sourceIdentity: source?.identity,
      sourceHash: source?.sha256,
      sourceType: source?.type.name,
      targetIdentity: target?.identity,
      targetHash: target?.sha256,
      targetType: target?.type.name,
      targetMissing: target == null,
      sessionKey: context.sessionKey!,
      allowedTools: allowedTools,
      selectedAgentId: selectedAgentId,
      workspaceBindingSnapshot: context.workspaceBinding!.snapshot
          .withRootIdentity(rootIdentity),
      createdAt: now,
      expiresAt: now.add(const Duration(minutes: 15)),
    );
  }

  @override
  Future<void> revalidateWorkspacePermission({
    required PendingWorkspaceProposal proposal,
    required String? selectedAgentId,
    required Set<String> allowedTools,
  }) async {
    final compatibilityPermission =
        proposal.operation == 'write_file' &&
        proposal.path == 'session.md' &&
        proposal.allowedTools.contains('write_session_notes');
    if (selectedAgentId != proposal.selectedAgentId ||
        (!allowedTools.contains(proposal.operation) &&
            !(compatibilityPermission &&
                allowedTools.contains('write_session_notes')))) {
      throw const WorkspaceBoundaryException('permission_changed');
    }
    final tools = await _agentTools(selectedAgentId!);
    if (tools == null ||
        (!tools.contains(proposal.operation) &&
            !(compatibilityPermission &&
                tools.contains('write_session_notes')))) {
      throw const WorkspaceBoundaryException('permission_changed');
    }
  }

  Future<SessionWorkspaceAuthority> _authority(
    ChatToolExecutionContext? context, {
    required String requestId,
  }) async {
    final binding = context?.workspaceBinding;
    final key = context?.sessionKey;
    if (context == null || binding == null || key == null || key.isEmpty) {
      throw const WorkspaceBoundaryException('workspace_unavailable');
    }
    final repository = _memoryRepository;
    if (repository == null) {
      throw const WorkspaceBoundaryException('workspace_unavailable');
    }
    final boundary = createChatWorkspaceBoundary(binding, key, repository);
    final rootIdentity = await boundary.rootIdentity();
    final persistedRootIdentity = binding.snapshot.rootIdentity;
    if (persistedRootIdentity != null &&
        persistedRootIdentity != rootIdentity) {
      throw const WorkspaceBoundaryException('workspace_binding_changed');
    }
    final coordinator = WorkspaceMutationCoordinator(
      rootIdentity: rootIdentity,
      sessionKey: key,
      boundary: boundary,
      journal: HiveWorkspaceRecoveryJournal(),
    );
    return SessionWorkspaceAuthority(
      conversationId: context.conversationId,
      requestId: requestId,
      sessionKey: key,
      binding: binding,
      rootIdentity: rootIdentity,
      boundary: boundary,
      recover: coordinator.recoverLocked,
    );
  }

  String _proposalPath(String operation, Map<String, Object?> args) =>
      operation == 'move_file'
      ? requiredWorkspaceString(args, 'source')
      : requiredWorkspaceString(args, 'path');
  String _preview(String path, WorkspaceEntry? source, String content) {
    final preview = '${source == null ? 'CREATE' : 'REPLACE'} $path\n$content';
    if (utf8.encode(preview).length > workspaceMaxPreviewBytes) {
      throw const FormatException('workspace_preview_too_large');
    }
    return preview;
  }

  String _deletePreview(String path, WorkspaceReadResult source) {
    final lines = const LineSplitter().convert(source.content);
    final body = lines.map((line) => '-$line').join('\n');
    final preview = 'DELETE $path\n$body';
    if (utf8.encode(preview).length > workspaceMaxPreviewBytes) {
      throw const FormatException('workspace_preview_too_large');
    }
    return preview;
  }

  void _requireAllowed(String name, Set<String> allowed) {
    if (!allowed.contains(name)) {
      throw const FormatException('tool_not_allowed');
    }
  }
}
