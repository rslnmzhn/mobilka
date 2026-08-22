import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/agents/application/subagent_executor.dart';
import 'package:mobilka/features/agents/domain/agent_catalog.dart';
import 'package:mobilka/features/agents/domain/agent_definition.dart';
import 'package:mobilka/features/agents/domain/agent_graph.dart';
import 'package:mobilka/features/agents/domain/delegation.dart';
import 'package:mobilka/features/chat/data/chat_repository.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_stream_event.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';

void main() {
  test('contracts enforce bounds and copy mutable definition lists', () {
    expect(
      () => DelegationRequest(
        parentConversationId: 'conversation',
        parentRequestId: 'request',
        subagentId: 'runner',
        task: 'task',
        depth: 2,
      ),
      throwsArgumentError,
    );
    expect(
      () => DelegationResult(
        parentConversationId: 'conversation',
        parentRequestId: 'request',
        subagentId: 'runner',
        status: DelegationStatus.completed,
        content: 'x' * (DelegationResult.maxContentCharacters + 1),
      ),
      throwsArgumentError,
    );
    final source = ['runner'];
    final definition = _agent('primary', subagents: source);
    source.add('other');
    expect(definition.subagents, ['runner']);
  });

  test(
    'routes subagent prompt and preferred model without parent mutation',
    () async {
      final streamer = _RecordingStreamer(const [
        ChatStreamEvent(delta: 'answer'),
        ChatStreamEvent(isTerminal: true),
      ]);
      final parentHistory = <ChatMessage>[
        ChatMessage(
          id: 'parent-message',
          role: ChatRole.user,
          content: 'parent content',
          createdAt: DateTime.utc(2026),
        ),
      ];
      final executor = SubagentExecutor(streamer: streamer, graph: _graph());

      final result = await executor.execute(
        request: _request(),
        fallbackModel: 'fallback-model',
      );

      expect(result.status, DelegationStatus.completed);
      expect(result.content, 'answer');
      expect(result.parentConversationId, 'conversation-1');
      expect(result.parentRequestId, 'request-1');
      expect(streamer.model, 'preferred-model');
      expect(streamer.messages.first.role, ChatRole.system);
      expect(streamer.messages.first.content, 'Subagent prompt');
      expect(streamer.messages.last.content, contains('Context:\ncontext'));
      expect(parentHistory.single.content, 'parent content');
      expect(parentHistory, hasLength(1));
    },
  );

  test(
    'returns failure for premature close and unavailable subagent',
    () async {
      final executor = SubagentExecutor(
        streamer: _RecordingStreamer(const [ChatStreamEvent(delta: 'partial')]),
        graph: _graph(),
      );
      final premature = await executor.execute(
        request: _request(),
        fallbackModel: 'fallback',
      );
      final unavailable = await executor.execute(
        request: DelegationRequest(
          parentConversationId: 'conversation-1',
          parentRequestId: 'request-1',
          subagentId: 'other',
          task: 'task',
        ),
        fallbackModel: 'fallback',
      );
      expect(premature.status, DelegationStatus.failed);
      expect(premature.error, contains('closed before completion'));
      expect(unavailable.status, DelegationStatus.failed);
    },
  );

  test('cancellation returns a cancelled result with immutable IDs', () async {
    final streamer = _ControlledStreamer();
    final executor = SubagentExecutor(streamer: streamer, graph: _graph());
    final token = CancelToken();
    final running = executor.execute(
      request: _request(),
      fallbackModel: 'fallback',
      cancelToken: token,
    );
    await streamer.started.future;
    token.cancel();

    final result = await running;
    expect(result.status, DelegationStatus.cancelled);
    expect(result.parentConversationId, 'conversation-1');
    expect(result.parentRequestId, 'request-1');
  });
}

DelegationRequest _request() => DelegationRequest(
  parentConversationId: 'conversation-1',
  parentRequestId: 'request-1',
  subagentId: 'runner',
  task: 'Do work',
  context: 'context',
);

AgentGraph _graph() {
  final primary = _entry(_agent('primary', subagents: ['runner']));
  final runner = _entry(
    _agent(
      'runner',
      mode: AgentMode.subagent,
      prompt: 'Subagent prompt',
      model: 'preferred-model',
    ),
  );
  return const AgentGraphResolver().resolve(
    AgentCatalog(
      agents: [primary, runner],
      issues: const [],
      selectedId: 'primary',
    ),
  );
}

AgentCatalogEntry _entry(AgentDefinition definition) => AgentCatalogEntry(
  definition: definition,
  origin: AgentOrigin.user,
  location: definition.id,
  isHidden: false,
  isFavorite: false,
);

AgentDefinition _agent(
  String id, {
  AgentMode mode = AgentMode.primary,
  List<String> subagents = const [],
  String prompt = 'prompt',
  String? model,
}) => AgentDefinition(
  id: id,
  name: id,
  description: id,
  mode: mode,
  prompt: prompt,
  modelPreference: model,
  subagents: subagents,
);

class _RecordingStreamer implements SubagentCompletionStreamer {
  _RecordingStreamer(this.events);
  final List<ChatStreamEvent> events;
  String? model;
  List<ChatMessage> messages = const [];

  @override
  Stream<ChatStreamEvent> streamSubagentCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
    List<ChatToolDefinition> tools = const [],
  }) {
    this.model = model;
    this.messages = messages;
    return Stream.fromIterable(events);
  }
}

class _ControlledStreamer implements SubagentCompletionStreamer {
  final started = Completer<void>();

  @override
  Stream<ChatStreamEvent> streamSubagentCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
  }) async* {
    started.complete();
    await cancelToken.whenCancel;
  }
}
