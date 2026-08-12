import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/memory/application/context_injector.dart';

void main() {
  test('prepends agent then selected memory in deterministic order', () async {
    final injector = ContextInjector(
      _MemorySource({
        'user_profile.md': 'Profile',
        'system_instructions.md': 'Instructions',
        'memory_log.md': 'Log',
      }),
      const _AgentSource('Agent prompt'),
      () => {'user_profile.md', 'system_instructions.md', 'memory_log.md'},
    );
    final result = await injector.inject([
      ChatMessage(
        id: 'user-1',
        role: ChatRole.user,
        content: 'Hello',
        createdAt: DateTime(2026),
      ),
    ]);

    expect(result.first.role, ChatRole.system);
    final prompt = result.first.content;
    expect(
      prompt.indexOf('<active_agent>'),
      lessThan(prompt.indexOf('system_instructions.md')),
    );
    expect(
      prompt.indexOf('system_instructions.md'),
      lessThan(prompt.indexOf('user_profile.md')),
    );
    expect(
      prompt.indexOf('user_profile.md'),
      lessThan(prompt.indexOf('memory_log.md')),
    );
    expect(result.last.content, 'Hello');
  });

  test('skips missing and unreadable selected files', () async {
    final injector = ContextInjector(
      _MemorySource(
        {'user_profile.md': 'Profile'},
        unreadable: {'project_context.md'},
      ),
      const _AgentSource(null),
      () => {'user_profile.md', 'project_context.md'},
    );
    final result = await injector.inject(const []);
    expect(result.single.content, contains('Profile'));
    expect(result.single.content, isNot(contains('project_context.md')));
  });

  test('does not add a system message when all sources are empty', () async {
    final result = await ContextInjector(
      _MemorySource(const {}),
      const _AgentSource(null),
      () => const {},
    ).inject(const []);
    expect(result, isEmpty);
  });
}

class _MemorySource implements MemoryContextSource {
  _MemorySource(this.values, {this.unreadable = const {}});
  final Map<String, String> values;
  final Set<String> unreadable;

  @override
  Future<Map<String, String>> readSnapshot(Iterable<String> fileNames) async {
    return {
      for (final fileName in fileNames)
        if (!unreadable.contains(fileName) && values[fileName] != null)
          fileName: values[fileName]!,
    };
  }
}

class _AgentSource implements AgentPromptSource {
  const _AgentSource(this.value);
  final String? value;

  @override
  Future<String?> readActivePrompt() async => value;
}
