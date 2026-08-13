import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    selectedAgent: () async =>
        (await ref.read(agentsControllerProvider.future)).selected,
    memoryUpdates: ref.watch(updateMemoryFileProvider),
  );
});

class MemoryChatToolRuntime implements ChatToolRuntime, MemoryProposalRuntime {
  MemoryChatToolRuntime({
    required Future<AgentCatalogEntry?> Function() selectedAgent,
    required UpdateMemoryFileService? memoryUpdates,
    DateTime Function()? now,
  }) : _selectedAgent = selectedAgent,
       _memoryUpdates = memoryUpdates,
       _now = now ?? DateTime.now;

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

  final Future<AgentCatalogEntry?> Function() _selectedAgent;
  final UpdateMemoryFileService? _memoryUpdates;
  final DateTime Function() _now;

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async {
    if (_memoryUpdates != null &&
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
    Set<String> allowedTools,
  ) async {
    if (call.name != updateMemoryFile.name) return null;
    _requireAllowed(call.name, allowedTools);
    if (selectedAgentId == null) {
      throw MemoryToolPermissionException('No agent is bound to request');
    }
    final updates = _memoryUpdates;
    if (updates == null) throw StateError('Memory storage is not configured');
    final arguments = _decodeArguments(call.arguments);
    final fileName = arguments['file_name'] as String;
    final proposedContent = arguments['content'] as String;
    final preview = await updates.preparePreview(fileName, proposedContent);
    return PendingMemoryProposal(
      toolCallId: call.id,
      assistantMessageId: assistantMessageId,
      selectedAgentId: selectedAgentId,
      allowedTools: allowedTools,
      fileName: fileName,
      proposedContent: proposedContent,
      diff: preview.diff,
      confirmationToken: preview.confirmationToken,
      version: preview.version,
      createdAt: _now().toUtc(),
    );
  }

  @override
  Future<void> revalidateMemoryProposal(PendingMemoryProposal proposal) async {
    _requireAllowed(updateMemoryFile.name, proposal.allowedTools);
    final selected = await _selectedAgent();
    if (selected?.definition.id != proposal.selectedAgentId ||
        !selected!.definition.tools.contains(updateMemoryFile.name)) {
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
