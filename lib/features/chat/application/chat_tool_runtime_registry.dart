import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../features/memory/application/skills_chat_tools.dart';
import '../../../features/memory/application/session_notes_tools.dart';
import '../../../features/memory/application/workspace_paths.dart';
import '../../../features/memory/data/memory_repository.dart';
import 'chat_controller.dart';
import '../../../features/memory/application/persona_chat_tools.dart';
import '../../artifacts/application/artifacts_chat_tool_runtime.dart';
import '../../chat/domain/chat_message.dart';
import '../../chat/domain/chat_tool.dart';
import '../../chat/domain/pending_memory_proposal.dart';
import '../../memory/application/memory_chat_tool_runtime.dart';
import 'chat_tool_runtime.dart';

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

final sessionNotesToolsProvider = Provider<SessionNotesTools>((ref) {
  final workspace = WorkspaceStore(
    repository: ref.watch(memoryRepositoryProvider),
  );
  String? key() {
    final state = ref.watch(chatControllerProvider).value;
    final conversation = state?.activeConversation;
    if (conversation == null) return null;
    return WorkspaceStore.sessionKey(
      createdAt: conversation.createdAt,
      title: conversation.title,
    );
  }

  return SessionNotesTools(workspace: workspace, sessionKey: key);
});

final chatToolRuntimeRegistryProvider = Provider<CompositeChatToolRuntime>((
  ref,
) {
  return CompositeChatToolRuntime([
    ref.watch(artifactsChatToolRuntimeProvider),
    ref.watch(skillsChatToolsProvider),
    ref.watch(sessionNotesToolsProvider),
    ref.watch(personaChatToolsProvider),
    ref.watch(memoryChatToolRuntimeProvider),
  ]);
});

class CompositeChatToolRuntime
    implements ChatToolRuntime, MemoryProposalRuntime {
  CompositeChatToolRuntime(this._runtimes);

  final List<ChatToolRuntime> _runtimes;

  MemoryProposalRuntime? get _proposalRuntime {
    for (final runtime in _runtimes) {
      if (runtime is MemoryProposalRuntime) {
        return runtime as MemoryProposalRuntime;
      }
    }
    return null;
  }

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async {
    final definitions = <ChatToolDefinition>[];
    final seen = <String>{};
    for (final runtime in _runtimes) {
      for (final definition in await runtime.availableTools(allowedTools)) {
        if (seen.add(definition.name)) {
          definitions.add(definition);
        }
      }
    }
    return definitions;
  }

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools,
  ) async {
    for (final runtime in _runtimes) {
      final advertised = await runtime.availableTools(allowedTools);
      if (advertised.any((definition) => definition.name == call.name)) {
        return runtime.executeTool(call, allowedTools);
      }
    }
    throw StateError('Unknown executable tool: ${call.name}');
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
}
