import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime_registry.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/chat/domain/pending_memory_proposal.dart';
import 'package:mobilka/features/agents/data/agent_definition_parser.dart';
import 'package:mobilka/core/logging/app_logger.dart';

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

  test('unknown tool returns a safe execution envelope', () async {
    final composite = CompositeChatToolRuntime([
      _StubRuntime(name: 'known_tool', id: 'x'),
    ]);

    expect(
      await composite.executeTool(
        const ChatToolCall(id: 'call', name: 'other', arguments: '{}'),
        const {'allowed'},
      ),
      '{"ok":false,"error_code":"unknown_tool"}',
    );
  });

  test(
    'one unavailable runtime is omitted without hiding other tools',
    () async {
      final logs = <AppLogEntry>[];
      final composite = CompositeChatToolRuntime([
        RegisteredChatToolRuntime(
          'broken',
          () => const _ThrowingRuntime(),
          failurePolicy: ChatToolRuntimeFailurePolicy.omitOnAvailabilityFailure,
        ),
        RegisteredChatToolRuntime(
          'working',
          () => _StubRuntime(name: 'working_tool', id: 'working'),
        ),
      ], logger: AppLogger(sink: logs.add));

      final tools = await composite.availableTools(const {'allowed'});

      expect(tools.map((tool) => tool.name), ['working_tool']);
      expect(logs.single.event, 'chat.tool_availability');
      expect(logs.single.runtimeId, 'broken');
      expect(logs.single.errorType, 'UnsupportedError');
      expect(logs.single.errorCode, 'unsupported_operation');
      expect(logs.single.stackFingerprint, startsWith('sha256:'));
      expect(logs.single.toJson().toString(), isNot(contains('unavailable')));
    },
  );

  test(
    'optional lookup failure continues to a later matching runtime',
    () async {
      final composite = CompositeChatToolRuntime([
        RegisteredChatToolRuntime(
          'broken',
          () => const _ThrowingRuntime(),
          failurePolicy: ChatToolRuntimeFailurePolicy.omitOnAvailabilityFailure,
        ),
        RegisteredChatToolRuntime(
          'working',
          () => _StubRuntime(name: 'broken_tool', id: 'working'),
        ),
      ]);

      expect(
        await composite.executeTool(
          const ChatToolCall(id: 'call', name: 'broken_tool', arguments: '{}'),
          const {'allowed', 'broken_tool'},
        ),
        '{}',
      );
    },
  );

  test('optional constructor failure is omitted', () async {
    final composite = CompositeChatToolRuntime([
      RegisteredChatToolRuntime(
        'broken',
        () => throw UnsupportedError('secret material'),
        failurePolicy: ChatToolRuntimeFailurePolicy.omitOnAvailabilityFailure,
      ),
      RegisteredChatToolRuntime(
        'working',
        () => _StubRuntime(name: 'working_tool', id: 'working'),
      ),
    ]);

    expect(
      (await composite.availableTools(const {'allowed'})).single.name,
      'working_tool',
    );
  });

  test('required runtime failures rethrow', () async {
    final constructorFailure = CompositeChatToolRuntime([
      RegisteredChatToolRuntime(
        'required',
        () => throw UnsupportedError('required constructor'),
      ),
    ]);
    final availabilityFailure = CompositeChatToolRuntime([
      RegisteredChatToolRuntime('required', () => const _ThrowingRuntime()),
    ]);

    await expectLater(
      constructorFailure.availableTools(const {'allowed'}),
      throwsUnsupportedError,
    );
    await expectLater(
      availabilityFailure.availableTools(const {'allowed'}),
      throwsUnsupportedError,
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

  test(
    'production registry and bundled default agree on exact 13 agent tools',
    () async {
      Hive.init(
        Directory.systemTemp.createTempSync('registry-inventory-').path,
      );
      await Hive.openBox<dynamic>('preferences');
      addTearDown(() async {
        await Hive.deleteBoxFromDisk('preferences');
        await Hive.close();
      });
      final definition = const AgentDefinitionParser().parse(
        File('assets/agents/general-assistant.md').readAsStringSync(),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final runtime = container.read(chatToolRuntimeRegistryProvider);
      final advertised = await runtime.availableTools(definition.tools.toSet());
      expect(definition.tools, hasLength(13));
      expect(
        advertised.map((tool) => tool.name).toSet(),
        definition.tools.toSet().difference({
          'update_memory_file',
          'web_search',
        }),
      );
      expect(runtime, isA<MemoryProposalRuntime>());
      final effects = {for (final tool in advertised) tool.name: tool.effect};
      expect(effects['read_public_source'], ChatToolEffect.readOnly);
      expect(effects['write_skill'], isNull);
      expect(effects['propose_skill'], ChatToolEffect.runtimeConfirmed);
      expect(effects['generate_docx'], ChatToolEffect.mutating);
    },
  );
}

class _ThrowingRuntime implements ChatToolRuntime {
  const _ThrowingRuntime();

  @override
  Future<List<ChatToolDefinition>> availableTools(Set<String> allowedTools) {
    throw UnsupportedError('runtime unavailable');
  }

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) async => throw StateError('must not execute');
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
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) {
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

  @override
  Future<void> revalidateMemoryToolPermission({
    required String toolName,
    required String? selectedAgentId,
    required Set<String> allowedTools,
  }) async {
    revalidated = true;
  }
}
