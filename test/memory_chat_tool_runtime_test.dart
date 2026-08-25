import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/agents/domain/agent_catalog.dart';
import 'package:mobilka/features/agents/domain/agent_definition.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/pending_memory_proposal.dart';
import 'package:mobilka/features/memory/application/memory_chat_tool_runtime.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/application/update_memory_file_service.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'support/memory_delete_mixins.dart';

void main() {
  late _MemoryBoundary boundary;
  late UpdateMemoryFileService updates;

  setUp(() {
    boundary = _MemoryBoundary({
      'user.md': '# User\nold\n',

      'soul.md': '# Instructions\n',
      'memory.md': '# Memory Log\n',
    });
    updates = UpdateMemoryFileService(
      boundary,
      MemoryMutationCoordinator(boundary),
      tokenFactory: () => 'confirmation-token',
    );
  });

  test(
    'exposes update_memory_file only to an authorized selected agent',
    () async {
      final authorized = _runtime(updates, tools: const ['update_memory_file']);
      final unauthorized = _runtime(updates);

      expect(
        (await authorized.availableTools(const {
          'update_memory_file',
        })).single.name,
        'update_memory_file',
      );
      expect(await unauthorized.availableTools(const {}), isEmpty);
      expect(
        MemoryChatToolRuntime
            .updateMemoryFile
            .parameters['additionalProperties'],
        isFalse,
      );
    },
  );

  test(
    'prepares a proposal without mutating memory before confirmation',
    () async {
      final runtime = _runtime(updates, tools: const ['update_memory_file']);

      final proposal = await runtime.prepareMemoryProposal(
        const ChatToolCall(
          id: 'call-1',
          name: 'update_memory_file',
          arguments: '{"file_name":"user.md","content":"# User\\nnew\\n"}',
        ),
        'assistant-1',
        'agent',
        const {'update_memory_file'},
      );

      expect(proposal?.proposedContent, '# User\nnew\n');
      expect(boundary.files['user.md'], '# User\nold\n');
      expect(boundary.writes, isEmpty);
    },
  );

  test(
    'strict arguments reject extras without preparing or mutating',
    () async {
      final runtime = _runtime(updates, tools: const ['update_memory_file']);

      await expectLater(
        runtime.prepareMemoryProposal(
          const ChatToolCall(
            id: 'call-1',
            name: 'update_memory_file',
            arguments: '{"file_name":"user.md","content":"new","extra":true}',
          ),
          'assistant-1',
          'agent',
          const {'update_memory_file'},
        ),
        throwsFormatException,
      );
      expect(boundary.writes, isEmpty);
    },
  );

  test('executeTool cannot apply update_memory_file', () async {
    final runtime = _runtime(updates, tools: const ['update_memory_file']);

    await expectLater(
      runtime.executeTool(
        const ChatToolCall(
          id: 'call-1',
          name: 'update_memory_file',
          arguments: '{"file_name":"user.md","content":"# User\\nnew\\n"}',
        ),
        const {'update_memory_file'},
      ),
      throwsFormatException,
    );
    expect(boundary.files['user.md'], '# User\nold\n');
    expect(boundary.writes, isEmpty);
  });

  test('unauthorized selected agent cannot prepare a proposal', () async {
    final runtime = _runtime(updates);

    await expectLater(
      runtime.prepareMemoryProposal(
        const ChatToolCall(
          id: 'call-1',
          name: 'update_memory_file',
          arguments: '{"file_name":"user.md","content":"# User\\nnew\\n"}',
        ),
        'assistant-1',
        'agent',
        const {},
      ),
      throwsStateError,
    );
    expect(boundary.writes, isEmpty);
  });

  test(
    'selection change during stream cannot grant a snapshotted tool',
    () async {
      final runtime = _runtime(updates, tools: const ['update_memory_file']);
      expect(await runtime.availableTools(const {}), isEmpty);
      await expectLater(
        runtime.prepareMemoryProposal(
          const ChatToolCall(
            id: 'call-1',
            name: 'update_memory_file',
            arguments: '{"file_name":"user.md","content":"new"}',
          ),
          'assistant-1',
          'agent',
          const {},
        ),
        throwsStateError,
      );
      expect(boundary.writes, isEmpty);
    },
  );

  test('permission revoked before confirmation blocks mutation', () async {
    var selected = _entry(const ['update_memory_file']);
    final runtime = MemoryChatToolRuntime(
      agentById: (_) async => selected,
      memoryUpdates: () => updates,
    );
    final proposal = await _proposal(runtime);
    selected = _entry(const []);

    await expectLater(
      runtime.revalidateMemoryProposal(proposal),
      throwsStateError,
    );
    expect(boundary.writes, isEmpty);
  });

  test('valid unchanged permission permits mutation', () async {
    final runtime = _runtime(updates, tools: const ['update_memory_file']);
    final proposal = await _proposal(runtime);
    await runtime.revalidateMemoryProposal(proposal);
    await updates.applyPersisted(
      fileName: proposal.fileName,
      proposedContent: proposal.proposedContent,
      diff: proposal.diff,
      confirmationToken: proposal.confirmationToken,
      version: proposal.version,
      createdAt: proposal.createdAt,
    );
    expect(boundary.files['user.md'], '# User\nnew\n');
  });

  test('revalidation resolves the proposal agent by id', () async {
    final runtime = MemoryChatToolRuntime(
      agentById: (id) async =>
          id == 'agent' ? _entry(const ['update_memory_file']) : null,
      memoryUpdates: () => updates,
    );

    await runtime.revalidateMemoryProposal(await _proposal(runtime));
  });
}

Future<PendingMemoryProposal> _proposal(MemoryChatToolRuntime runtime) async =>
    (await runtime.prepareMemoryProposal(
      const ChatToolCall(
        id: 'call-1',
        name: 'update_memory_file',
        arguments: '{"file_name":"user.md","content":"# User\\nnew\\n"}',
      ),
      'assistant-1',
      'agent',
      const {'update_memory_file'},
    ))!;

MemoryChatToolRuntime _runtime(
  UpdateMemoryFileService updates, {
  List<String> tools = const [],
}) => MemoryChatToolRuntime(
  agentById: (_) async => _entry(tools),
  memoryUpdates: () => updates,
);

AgentCatalogEntry _entry(List<String> tools) => AgentCatalogEntry(
  definition: AgentDefinition(
    id: 'agent',
    name: 'Agent',
    description: 'Agent',
    mode: AgentMode.primary,
    prompt: 'Prompt',
    tools: tools,
  ),
  origin: AgentOrigin.user,
  location: 'agent.md',
  isHidden: false,
  isFavorite: false,
);

class _MemoryBoundary with MemoryBoundaryDelete implements MemoryFileBoundary {
  _MemoryBoundary(this.files);

  final Map<String, String> files;
  final List<String> writes = [];

  @override
  Future<String> read(String fileName) async => files[fileName]!;

  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) => action(_MemoryTransaction(this));

  @override
  Future<void> write(String fileName, String content) async {
    writes.add(fileName);
    files[fileName] = content;
  }
}

class _MemoryTransaction
    implements MemoryFileTransaction, MissingAwareMemoryFileTransaction {
  const _MemoryTransaction(this.boundary);

  final _MemoryBoundary boundary;

  @override
  Future<String> read(String fileName) => boundary.read(fileName);

  @override
  Future<String?> readIfExists(String fileName) async =>
      boundary.files[fileName];

  @override
  Future<void> write(String fileName, String content) =>
      boundary.write(fileName, content);
}
