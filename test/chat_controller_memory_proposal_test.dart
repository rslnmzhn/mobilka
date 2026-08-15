import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/agents/domain/agent_catalog.dart';
import 'package:mobilka/features/agents/domain/agent_definition.dart';
import 'package:mobilka/features/chat/application/chat_controller.dart';
import 'package:mobilka/features/chat/data/chat_repository.dart';
import 'package:mobilka/features/chat/data/conversation_store.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_stream_event.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/chat/domain/pending_memory_proposal.dart';
import 'package:mobilka/features/memory/application/memory_chat_tool_runtime.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/application/update_memory_file_service.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chat-memory-confirm-');
    Hive.init(root.path);
    await Future.wait([
      Hive.openBox<dynamic>('conversations'),
      Hive.openBox<dynamic>('memory_recovery'),
    ]);
  });

  tearDown(() async {
    await Hive.close();
    await root.delete(recursive: true);
  });

  test(
    'confirm applies create, clears proposal, persists result, and continues',
    () async {
      final boundary = _Boundary();
      final updates = UpdateMemoryFileService(
        boundary,
        MemoryMutationCoordinator(boundary),
        tokenFactory: () => 'token',
      );
      final proposal = await _proposal(updates);
      await ConversationStore().save(_conversation(proposal));
      final container = _container(updates, permitsTool: true);
      addTearDown(container.dispose);
      await container.read(chatControllerProvider.future);

      await container
          .read(chatControllerProvider.notifier)
          .confirmPendingMemoryProposal();

      final conversation = container
          .read(chatControllerProvider)
          .requireValue
          .conversationById('conversation')!;
      expect(boundary.files['project_context.md'], '# Created\n');
      expect(conversation.pendingMemoryProposal, isNull);
      expect(
        conversation.messages.where((message) => message.role == ChatRole.tool),
        hasLength(1),
      );
      expect(conversation.messages.last.content, 'continued');
      expect(
        ConversationStore().loadAll().single.pendingMemoryProposal,
        isNull,
      );
    },
  );

  test(
    'confirm failure remains retryable and exposes actionable error',
    () async {
      final boundary = _Boundary();
      final updates = UpdateMemoryFileService(
        boundary,
        MemoryMutationCoordinator(boundary),
        tokenFactory: () => 'token',
      );
      final proposal = await _proposal(updates);
      await ConversationStore().save(_conversation(proposal));
      final container = _container(updates, permitsTool: false);
      addTearDown(container.dispose);
      await container.read(chatControllerProvider.future);

      await container
          .read(chatControllerProvider.notifier)
          .confirmPendingMemoryProposal();

      final state = container.read(chatControllerProvider).requireValue;
      expect(state.activeConversation!.pendingMemoryProposal, isNotNull);
      expect(state.errorMessage, isNotNull);
      expect(state.errorMessage, contains('memory'));
    },
  );
}

ProviderContainer _container(
  UpdateMemoryFileService updates, {
  required bool permitsTool,
}) => ProviderContainer(
  overrides: [
    updateMemoryFileProvider.overrideWithValue(updates),
    chatCompletionStreamerProvider.overrideWithValue(_Streamer()),
    memoryChatToolRuntimeProvider.overrideWithValue(
      MemoryChatToolRuntime(
        agentById: (_) async => permitsTool ? _agent() : null,
        memoryUpdates: updates,
      ),
    ),
  ],
);

Future<PendingMemoryProposal> _proposal(UpdateMemoryFileService updates) async {
  final preview = await updates.preparePreview(
    'project_context.md',
    '# Created\n',
  );
  return PendingMemoryProposal(
    toolCallId: 'call',
    assistantMessageId: 'assistant-tool-call',
    selectedAgentId: 'agent',
    allowedTools: const {'update_memory_file'},
    fileName: preview.fileName,
    proposedContent: preview.proposedContent,
    diff: preview.diff,
    confirmationToken: preview.confirmationToken,
    version: preview.version,
    createdAt: DateTime.utc(2026),
  );
}

Conversation _conversation(PendingMemoryProposal proposal) => Conversation(
  id: 'conversation',
  title: 'Test',
  modelId: 'model',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  messages: [
    ChatMessage(
      id: 'assistant-tool-call',
      role: ChatRole.assistant,
      content: '',
      createdAt: DateTime.utc(2026),
      toolCalls: const [
        ChatToolCall(id: 'call', name: 'update_memory_file', arguments: '{}'),
      ],
    ),
  ],
  pendingRequestMessageId: 'request',
  pendingMemoryProposal: proposal,
);

AgentCatalogEntry _agent() => AgentCatalogEntry(
  definition: AgentDefinition(
    id: 'agent',
    name: 'Agent',
    description: 'Agent',
    mode: AgentMode.primary,
    prompt: 'Prompt',
    tools: const ['update_memory_file'],
  ),
  origin: AgentOrigin.user,
  location: 'agent.md',
  isHidden: false,
  isFavorite: false,
);

class _Streamer implements ChatCompletionStreamer {
  @override
  Stream<ChatStreamEvent> streamCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
    List<ChatToolDefinition> tools = const [],
  }) => Stream.fromIterable(const [
    ChatStreamEvent(delta: 'continued'),
    ChatStreamEvent(finishReason: 'stop', isTerminal: true),
  ]);
}

class _Boundary implements MemoryFileBoundary {
  final Map<String, String> files = {'memory_log.md': '# Memory Log\n'};

  @override
  Future<String> read(String fileName) async => files[fileName]!;

  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) => action(_Transaction(this));

  @override
  Future<void> write(String fileName, String content) async {
    files[fileName] = content;
  }
}

class _Transaction
    implements MemoryFileTransaction, MissingAwareMemoryFileTransaction {
  const _Transaction(this.boundary);

  final _Boundary boundary;

  @override
  Future<String> read(String fileName) => boundary.read(fileName);

  @override
  Future<String?> readIfExists(String fileName) async =>
      boundary.files[fileName];

  @override
  Future<void> write(String fileName, String content) =>
      boundary.write(fileName, content);
}
