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

class MemoryToolPermissionException extends StateError {
  MemoryToolPermissionException(super.message);
}

final memoryChatToolRuntimeProvider = Provider<MemoryChatToolRuntime>((ref) {
  return MemoryChatToolRuntime(
    agentById: (id) async {
      final catalog = await ref.read(agentsControllerProvider.future);
      return catalog.agents
          .where((agent) => agent.definition.id == id)
          .firstOrNull;
    },
    memoryUpdates: () => ref.read(updateMemoryFileProvider),
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
    name: 'update_memory_file',
    description:
        'Propose complete replacement Markdown for an approved memory file. '
        'The user must review and confirm the exact diff before it is written.',
    parameters: {
      'type': 'object',
      'properties': {
        'file_name': {
          'type': 'string',
          'enum': [
            'user_profile.md',
            'project_context.md',
            'system_instructions.md',
          ],
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
    Set<String> allowedTools,
  ) async {
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
    if (call.name != updateMemoryFile.name) return null;
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
      _requireAllowed(updateMemoryFile.name, proposal.allowedTools);
      final agent = await _agentById(proposal.selectedAgentId);
      if (agent == null ||
          !agent.definition.tools.contains(updateMemoryFile.name)) {
        throw MemoryToolPermissionException(
          'Agent memory permission changed; request a new update',
        );
      }
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

  void _requireAllowed(String toolName, Set<String> allowedTools) {
    if (!allowedTools.contains(toolName)) {
      throw MemoryToolPermissionException(
        'Tool was not allowed for this request: $toolName',
      );
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
