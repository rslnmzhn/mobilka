import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/core/logging/app_logger.dart';
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
import 'support/memory_delete_mixins.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chat-memory-confirm-');
    Hive.init(root.path);
    await Future.wait([
      Hive.openBox<dynamic>('conversations'),
      Hive.openBox<dynamic>('memory_recovery'),
      Hive.openBox<dynamic>('preferences'),
      Hive.openBox<dynamic>('artifacts'),
      Hive.openBox<dynamic>('memory_proposals'),
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
      expect(boundary.files['user.md'], '# Created\n');
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
      final logs = <AppLogEntry>[];
      final container = _container(
        updates,
        permitsTool: false,
        logger: AppLogger(sink: logs.add),
      );
      addTearDown(container.dispose);
      await container.read(chatControllerProvider.future);

      await container
          .read(chatControllerProvider.notifier)
          .confirmPendingMemoryProposal();

      final state = container.read(chatControllerProvider).requireValue;
      expect(state.activeConversation!.pendingMemoryProposal, isNotNull);
      expect(state.errorMessage, isNotNull);
      expect(state.errorMessage, contains('memory'));
      expect(
        logs.any(
          (entry) =>
              entry.event == 'memory.confirm' && entry.status == 'failed',
        ),
        isTrue,
      );
    },
  );

  test('unavailable service is visible, logged, and retryable', () async {
    final boundary = _Boundary();
    final updates = UpdateMemoryFileService(
      boundary,
      MemoryMutationCoordinator(boundary),
      tokenFactory: () => 'token',
    );
    final proposal = await _proposal(updates);
    await ConversationStore().save(_conversation(proposal));
    final logs = <AppLogEntry>[];
    final container = _container(
      null,
      permitsTool: true,
      logger: AppLogger(sink: logs.add),
    );
    addTearDown(container.dispose);
    await container.read(chatControllerProvider.future);

    await container
        .read(chatControllerProvider.notifier)
        .confirmPendingMemoryProposal();

    final state = container.read(chatControllerProvider).requireValue;
    expect(state.errorMessage, isNotNull);
    expect(state.activeConversation!.pendingMemoryProposal, isNotNull);
    expect(state.confirmingMemoryToolCallId, isNull);
    expect(
      logs.any(
        (entry) =>
            entry.event == 'memory.provider_availability' &&
            entry.status == 'unavailable',
      ),
      isTrue,
    );
  });

  test(
    'proposal identity rejects changed fields with the same tool call id',
    () {
      final original = PendingMemoryProposal(
        toolCallId: 'call',
        assistantMessageId: 'assistant',
        selectedAgentId: 'agent',
        allowedTools: const {'update_memory_file'},
        fileName: 'user.md',
        proposedContent: 'safe',
        diff: 'diff',
        confirmationToken: 'token',
        version: 'version',
        createdAt: DateTime.utc(2026),
      );
      final changed = PendingMemoryProposal(
        toolCallId: original.toolCallId,
        assistantMessageId: original.assistantMessageId,
        selectedAgentId: original.selectedAgentId,
        allowedTools: original.allowedTools,
        fileName: original.fileName,
        proposedContent: 'changed after revalidation',
        diff: original.diff,
        confirmationToken: original.confirmationToken,
        version: original.version,
        createdAt: original.createdAt,
      );

      expect(original.hasSameIdentity(changed), isFalse);
    },
  );

  test(
    'proposal change during revalidation is rejected before apply',
    () async {
      final boundary = _Boundary();
      final updates = UpdateMemoryFileService(
        boundary,
        MemoryMutationCoordinator(boundary),
        tokenFactory: () => 'token',
      );
      final proposal = await _proposal(updates);
      await ConversationStore().save(_conversation(proposal));
      late ProviderContainer container;
      var changed = false;
      container = _container(
        updates,
        permitsTool: true,
        agentById: (_) async {
          if (!changed) {
            changed = true;
            await container
                .read(chatControllerProvider.notifier)
                .rejectPendingMemoryProposal();
          }
          return _agent();
        },
      );
      addTearDown(container.dispose);
      await container.read(chatControllerProvider.future);

      await container
          .read(chatControllerProvider.notifier)
          .confirmPendingMemoryProposal();

      expect(boundary.files['user.md'], isNull);
      expect(
        container.read(chatControllerProvider).requireValue.errorMessage,
        isNotNull,
      );
    },
  );
}

ProviderContainer _container(
  UpdateMemoryFileService? updates, {
  required bool permitsTool,
  AppLogger? logger,
  Future<AgentCatalogEntry?> Function(String id)? agentById,
}) => ProviderContainer(
  overrides: [
    updateMemoryFileProvider.overrideWithValue(updates),
    if (logger != null) appLoggerProvider.overrideWithValue(logger),
    chatCompletionStreamerProvider.overrideWithValue(_Streamer()),
    memoryChatToolRuntimeProvider.overrideWithValue(
      MemoryChatToolRuntime(
        agentById: agentById ?? (_) async => permitsTool ? _agent() : null,
        memoryUpdates: () => updates,
        logger: logger,
      ),
    ),
  ],
);

Future<PendingMemoryProposal> _proposal(UpdateMemoryFileService updates) async {
  final preview = await updates.preparePreview('user.md', '# Created\n');
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
    createdAt: preview.createdAt,
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

class _Boundary with MemoryBoundaryDelete implements MemoryFileBoundary {
  final Map<String, String> files = {'memory.md': '# Memory Log\n'};

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
