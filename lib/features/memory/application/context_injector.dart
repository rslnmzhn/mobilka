import '../../chat/domain/chat_message.dart';
import '../domain/memory_file_names.dart';
import 'prompt_guard.dart';

abstract interface class MemoryContextSource {
  Future<Map<String, String>> readSnapshot(Iterable<String> fileNames);
}

abstract interface class AgentPromptSource {
  Future<String?> readActivePrompt();
}

/// Returns the active persona overlay text (already persona-body only), or
/// null when no persona is active.
typedef PersonaOverlaySource = Future<String?> Function();

class ContextInjector {
  const ContextInjector(
    this._memorySource,
    this._agentSource,
    this._personaOverlay, {
    PromptGuard guard = const PromptGuard(),
  }) : _guard = guard;

  final MemoryContextSource _memorySource;
  final AgentPromptSource _agentSource;
  final PersonaOverlaySource _personaOverlay;
  final PromptGuard _guard;

  /// Fixed role order for the Memory 2.0 scheme. memory.md is deliberately
  /// excluded: it feeds the NEXT session's context, not the current one.
  static const orderedMemoryFiles = ['soul.md', 'user.md'];

  Future<List<ChatMessage>> inject(List<ChatMessage> messages) async {
    final sections = <String>[];
    final agentPrompt = await _agentSource.readActivePrompt();
    if (agentPrompt != null && agentPrompt.trim().isNotEmpty) {
      sections.add('<active_agent>\n${agentPrompt.trim()}\n</active_agent>');
    }

    final memory = await _memorySource.readSnapshot(orderedMemoryFiles);
    final soul = memory['soul.md'];
    if (soul != null && soul.trim().isNotEmpty) {
      sections.add('<soul>\n${_guard.sanitize(soul).content.trim()}\n</soul>');
    } else {
      // Owner decision: empty/missing soul falls back to the built-in
      // personality baked into the domain constants.
      sections.add('<soul>\n${MemoryFiles.defaultSoul.trim()}\n</soul>');
    }

    final overlay = await _personaOverlay();
    if (overlay != null && overlay.trim().isNotEmpty) {
      sections.add(
        '<persona>\n${_guard.sanitize(overlay).content.trim()}\n</persona>',
      );
    }

    final user = memory['user.md'];
    if (user != null && user.trim().isNotEmpty) {
      sections.add('<user>\n${_guard.sanitize(user).content.trim()}\n</user>');
    }

    if (sections.isEmpty) return List.unmodifiable(messages);
    return List.unmodifiable([
      ChatMessage(
        id: 'context-${DateTime.now().microsecondsSinceEpoch}',
        role: ChatRole.system,
        content: sections.join('\n\n'),
        createdAt: DateTime.now(),
      ),
      ...messages,
    ]);
  }
}
