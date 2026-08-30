import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../agents/application/agents_controller.dart';
import '../../agents/domain/agent_catalog.dart';
import '../../chat/application/chat_tool_runtime.dart';
import '../../chat/domain/chat_message.dart';
import '../../chat/domain/chat_tool.dart';
import '../../chat/domain/pending_memory_proposal.dart';
import 'update_memory_file_service.dart';
import '../domain/memory_file_names.dart';

class MemoryToolPermissionException extends StateError {
  MemoryToolPermissionException(super.message);
}

final memoryChatToolRuntimeProvider = Provider<MemoryChatToolRuntime>((ref) {
  final updates = ref.watch(updateMemoryFileProvider);
  return MemoryChatToolRuntime(
    agentById: (id) async {
      final catalog = await ref.read(agentsControllerProvider.future);
      return catalog.agents
          .where((agent) => agent.definition.id == id)
          .firstOrNull;
    },
    memoryUpdates: () => updates,
    logger: ref.read(appLoggerProvider),
  );
});

class MemoryChatToolRuntime implements ChatToolRuntime, MemoryProposalRuntime {
  MemoryChatToolRuntime({
    required Future<AgentCatalogEntry?> Function(String id) agentById,
    required UpdateMemoryFileService? Function() memoryUpdates,
    AppLogger? logger,
  }) : _agentById = agentById,
       _memoryUpdates = memoryUpdates,
       _logger = logger ?? AppLogger();

  static const updateMemoryFile = ChatToolDefinition(
    effect: ChatToolEffect.runtimeConfirmed,
    name: 'update_memory_file',
    description:
        'Write complete Markdown content to a memory file. '
        'user.md stores durable facts about the user (applied after explicit '
        'user confirmation of the diff). memory.md is your working notebook: '
        'tool findings, decisions, recurring patterns — applied instantly, '
        'and loaded into your context only on the next session or explicit '
        'context rebuild. Delete entries only when they are truly obsolete. '
        'soul.md cannot be changed by you.',
    parameters: {
      'type': 'object',
      'properties': {
        'file_name': {
          'type': 'string',
          'enum': ['user.md', 'memory.md'],
        },
        'content': {
          'type': 'string',
          'description': 'Complete proposed Markdown file content.',
        },
      },
      'required': ['file_name', 'content'],
      'additionalProperties': false,
    },
  );

  final Future<AgentCatalogEntry?> Function(String id) _agentById;
  final UpdateMemoryFileService? Function() _memoryUpdates;
  final AppLogger _logger;

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async {
    if (_memoryUpdates() != null &&
        allowedTools.contains(updateMemoryFile.name)) {
      return const [updateMemoryFile];
    }
    return const [];
  }

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) async {
    _requireAllowed(call.name, allowedTools);
    throw FormatException('Unknown executable tool: ${call.name}');
  }

  @override
  Future<PendingMemoryProposal?> prepareMemoryProposal(
    ChatToolCall call,
    String assistantMessageId,
    String? selectedAgentId,
    Set<String> allowedTools, [
    int callOccurrence = 0,
  ]) async {
    const personaMutations = {'save_persona', 'delete_persona'};
    if (call.name != updateMemoryFile.name &&
        !personaMutations.contains(call.name)) {
      return null;
    }
    _requireAllowed(call.name, allowedTools);
    if (selectedAgentId == null) {
      throw MemoryToolPermissionException('No agent is bound to request');
    }
    final updates = _memoryUpdates();
    _logger.log(
      event: 'memory.provider_availability',
      toolCallId: call.id,
      status: updates == null ? 'unavailable' : 'available',
      level: updates == null ? AppLogLevel.warning : AppLogLevel.debug,
    );
    if (updates == null) throw StateError('Memory storage is not configured');
    final arguments = _decodeArguments(call.arguments);
    final fileName = arguments['file_name'] as String;
    _validateProposalTarget(call.name, fileName);
    final proposedContent = arguments['content'] as String;
    final stopwatch = Stopwatch()..start();
    _logger.log(
      event: 'memory.proposal_prepare',
      toolCallId: call.id,
      fileName: fileName,
      status: 'started',
    );
    late final MemoryUpdatePreview preview;
    try {
      preview = await updates.preparePreview(fileName, proposedContent);
      _logger.log(
        event: 'memory.proposal_prepare',
        toolCallId: call.id,
        fileName: fileName,
        status: 'succeeded',
        duration: stopwatch.elapsed,
      );
    } on Object catch (error) {
      _logger.log(
        event: 'memory.proposal_prepare',
        level: AppLogLevel.error,
        toolCallId: call.id,
        fileName: fileName,
        status: 'failed',
        error: error,
        duration: stopwatch.elapsed,
      );
      rethrow;
    }
    return PendingMemoryProposal(
      toolCallId: call.id,
      assistantMessageId: assistantMessageId,
      callOccurrence: callOccurrence,
      selectedAgentId: selectedAgentId,
      allowedTools: allowedTools,
      fileName: fileName,
      proposedContent: proposedContent,
      diff: preview.diff,
      confirmationToken: preview.confirmationToken,
      version: preview.version,
      createdAt: preview.createdAt,
      requiredToolPermission: call.name,
    );
  }

  @override
  Future<void> revalidateMemoryProposal(PendingMemoryProposal proposal) async {
    _logger.log(
      event: 'memory.agent_revalidation',
      toolCallId: proposal.toolCallId,
      fileName: proposal.fileName,
      status: 'started',
    );
    try {
      validateMemoryProposalPermissionBinding(
        proposal.requiredToolPermission,
        proposal.fileName,
      );
      await revalidateMemoryToolPermission(
        toolName: proposal.requiredToolPermission,
        selectedAgentId: proposal.selectedAgentId,
        allowedTools: proposal.allowedTools,
      );
      _logger.log(
        event: 'memory.agent_revalidation',
        toolCallId: proposal.toolCallId,
        fileName: proposal.fileName,
        status: 'succeeded',
      );
    } on Object catch (error) {
      _logger.log(
        event: 'memory.agent_revalidation',
        level: AppLogLevel.error,
        toolCallId: proposal.toolCallId,
        fileName: proposal.fileName,
        status: 'failed',
        error: error,
      );
      rethrow;
    }
  }

  @override
  Future<void> revalidateMemoryToolPermission({
    required String toolName,
    required String? selectedAgentId,
    required Set<String> allowedTools,
  }) async {
    _requireAllowed(toolName, allowedTools);
    if (selectedAgentId == null) {
      throw MemoryToolPermissionException('No agent is bound to request');
    }
    final agent = await _agentById(selectedAgentId);
    if (agent == null || !agent.definition.tools.contains(toolName)) {
      throw MemoryToolPermissionException(
        'Agent memory permission changed; request a new update',
      );
    }
  }

  void _requireAllowed(String toolName, Set<String> allowedTools) {
    if (!allowedTools.contains(toolName)) {
      throw MemoryToolPermissionException(
        'Tool was not allowed for this request: $toolName',
      );
    }
  }

  void _validateProposalTarget(String toolName, String fileName) {
    if (toolName == updateMemoryFile.name) {
      if (fileName == MemoryFiles.memory) {
        throw const FormatException(
          'memory.md must use the instant memory write path',
        );
      }
      if (!MemoryFiles.confirmTargets.contains(fileName)) {
        throw FormatException(
          'update_memory_file cannot target model-protected file: $fileName',
        );
      }
      return;
    }
    if (!RegExp(
      r'^personas/[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?\.md$',
    ).hasMatch(fileName)) {
      throw FormatException('$toolName requires a canonical persona path');
    }
  }

  Map<String, dynamic> _decodeArguments(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 2 ||
        !decoded.containsKey('file_name') ||
        !decoded.containsKey('content') ||
        decoded['file_name'] is! String ||
        decoded['content'] is! String) {
      throw const FormatException(
        'update_memory_file requires exactly string file_name and content arguments',
      );
    }
    return decoded;
  }
}
