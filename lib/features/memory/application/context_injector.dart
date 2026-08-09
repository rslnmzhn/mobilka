import '../../chat/domain/chat_message.dart';

abstract interface class MemoryContextSource {
  Future<String?> readSelected(String fileName);
}

abstract interface class AgentPromptSource {
  Future<String?> readActivePrompt();
}

class ContextInjector {
  const ContextInjector(this._memorySource, this._agentSource);

  final MemoryContextSource _memorySource;
  final AgentPromptSource _agentSource;

  static const orderedMemoryFiles = [
    'system_instructions.md',
    'user_profile.md',
    'project_context.md',
    'memory_log.md',
  ];

  Future<List<ChatMessage>> inject(List<ChatMessage> messages) async {
    final sections = <String>[];
    final agentPrompt = await _agentSource.readActivePrompt();
    if (agentPrompt != null && agentPrompt.trim().isNotEmpty) {
      sections.add('<active_agent>\n${agentPrompt.trim()}\n</active_agent>');
    }
    for (final fileName in orderedMemoryFiles) {
      final content = await _memorySource.readSelected(fileName);
      if (content != null && content.trim().isNotEmpty) {
        sections.add(
          '<memory_file name="$fileName">\n${content.trim()}\n</memory_file>',
        );
      }
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
