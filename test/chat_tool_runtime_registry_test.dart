import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime_registry.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/chat/domain/pending_memory_proposal.dart';

void main() {
  test('composite dedupes advertised tools across runtimes', () async {
    final composite = CompositeChatToolRuntime([
      _StubRuntime(name: 'shared_tool', id: 'a'),
      _StubRuntime(name: 'shared_tool', id: 'b'),
      _StubRuntime(name: 'unique_tool', id: 'c'),
    ]);

    final tools = await composite.availableTools(const {'allowed'});

    expect(tools.map((tool) => tool.name), ['shared_tool', 'unique_tool']);
  });

  test('executeTool dispatches only to advertising runtimes', () async {
    final first = _StubRuntime(name: 'first_tool', id: 'first');
    final second = _StubRuntime(name: 'second_tool', id: 'second');
    final composite = CompositeChatToolRuntime([first, second]);

    await composite.executeTool(
      const ChatToolCall(id: 'call', name: 'second_tool', arguments: '{}'),
      const {'allowed'},
    );

    expect(first.executed, isFalse);
    expect(second.executed, isTrue);
  });

  test('unknown tool fails with StateError', () async {
    final composite = CompositeChatToolRuntime([
      _StubRuntime(name: 'known_tool', id: 'x'),
    ]);

    expect(
      () => composite.executeTool(
        const ChatToolCall(id: 'call', name: 'other', arguments: '{}'),
        const {'allowed'},
      ),
      throwsStateError,
    );
  });

  test('forwards MemoryProposalRuntime to the child providing it', () async {
    final memory = _ProposalCapableRuntime();
    final composite = CompositeChatToolRuntime([
      _StubRuntime(name: 'plain_tool', id: 'plain'),
      memory,
    ]);

    expect(composite, isA<MemoryProposalRuntime>());
    final asProposal = composite as MemoryProposalRuntime;
    final call = const ChatToolCall(
      id: 'call',
      name: 'update_memory_file',
      arguments: '{}',
    );
    final proposal = await asProposal.prepareMemoryProposal(
      call,
      'assistant',
      null,
      const {},
    );

    expect(memory.prepared, isTrue);
    expect(proposal?.assistantMessageId, 'assistant');
    await asProposal.revalidateMemoryProposal(proposal!);
    expect(memory.revalidated, isTrue);
  });

  test('production registry exposes a proposal-capable runtime', () async {
    Hive.init(Directory.systemTemp.createTempSync('registry-test').path);
    await Hive.openBox<dynamic>('preferences');
    addTearDown(() async {
      await Hive.deleteBoxFromDisk('preferences');
      await Hive.close();
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(chatToolRuntimeRegistryProvider),
      isA<MemoryProposalRuntime>(),
    );
  });
}

class _StubRuntime implements ChatToolRuntime {
  _StubRuntime({required this.name, required this.id});

  final String name;
  final String id;
  bool executed = false;

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async {
    if (allowedTools.contains('allowed')) {
      return [
        ChatToolDefinition(name: name, description: id, parameters: const {}),
      ];
    }
    return const [];
  }

  @override
  Future<String> executeTool(ChatToolCall call, Set<String> allowedTools) {
    executed = true;
    return Future.value('{}');
  }
}

class _ProposalCapableRuntime extends _StubRuntime
    implements MemoryProposalRuntime {
  _ProposalCapableRuntime() : super(name: 'update_memory_file', id: 'memory');

  bool prepared = false;
  bool revalidated = false;

  @override
  Future<PendingMemoryProposal?> prepareMemoryProposal(
    ChatToolCall call,
    String assistantMessageId,
    String? selectedAgentId,
    Set<String> allowedTools, [
    int callOccurrence = 0,
  ]) async {
    prepared = true;
    return PendingMemoryProposal(
      toolCallId: call.id,
      assistantMessageId: assistantMessageId,
      selectedAgentId: 'agent',
      allowedTools: allowedTools,
      fileName: 'user.md',
      proposedContent: '# new',
      diff: '+new',
      confirmationToken: 'token',
      version: 'version',
      createdAt: DateTime(2026),
    );
  }

  @override
  Future<void> revalidateMemoryProposal(PendingMemoryProposal proposal) async {
    revalidated = true;
  }
}
