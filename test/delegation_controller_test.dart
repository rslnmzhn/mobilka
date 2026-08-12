import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/agents/application/delegation_controller.dart';
import 'package:mobilka/features/agents/application/subagent_executor.dart';
import 'package:mobilka/features/agents/domain/agent_catalog.dart';
import 'package:mobilka/features/agents/domain/agent_definition.dart';
import 'package:mobilka/features/agents/domain/agent_graph.dart';
import 'package:mobilka/features/chat/data/chat_repository.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_stream_event.dart';

void main() {
  test('owns validation failure without invoking execution', () async {
    final streamer = _Streamer(const []);
    final container = _container(streamer);
    addTearDown(container.dispose);

    await container
        .read(delegationControllerProvider.notifier)
        .execute(
          parentConversationId: '',
          parentRequestId: 'request',
          subagentId: 'runner',
          task: 'task',
          context: '',
          fallbackModel: 'fallback',
        );

    final state = container.read(delegationControllerProvider);
    expect(state.status, DelegationExecutionStatus.failed);
    expect(state.error, isNotEmpty);
    expect(streamer.calls, 0);
  });

  test('owns completed status and result', () async {
    final container = _container(
      _Streamer(const [
        ChatStreamEvent(delta: 'answer'),
        ChatStreamEvent(isTerminal: true),
      ]),
    );
    addTearDown(container.dispose);

    await _execute(container);

    final state = container.read(delegationControllerProvider);
    expect(state.status, DelegationExecutionStatus.completed);
    expect(state.result?.content, 'answer');
    expect(state.error, isNull);
  });

  test('owns cancellation and cancelled result', () async {
    final streamer = _ControlledStreamer();
    final container = _container(streamer);
    addTearDown(container.dispose);

    final execution = _execute(container);
    await streamer.started.future;
    expect(
      container.read(delegationControllerProvider).status,
      DelegationExecutionStatus.running,
    );

    container.read(delegationControllerProvider.notifier).cancel();
    await execution;

    final state = container.read(delegationControllerProvider);
    expect(state.status, DelegationExecutionStatus.cancelled);
    expect(state.result?.status.name, 'cancelled');
  });
}

ProviderContainer _container(SubagentCompletionStreamer streamer) {
  final executor = SubagentExecutor(streamer: streamer, graph: _graph());
  final container = ProviderContainer(
    overrides: [subagentExecutorProvider.overrideWith((ref) async => executor)],
  );
  container.listen(delegationControllerProvider, (_, _) {});
  return container;
}

Future<void> _execute(ProviderContainer container) => container
    .read(delegationControllerProvider.notifier)
    .execute(
      parentConversationId: 'conversation',
      parentRequestId: 'request',
      subagentId: 'runner',
      task: 'task',
      context: 'context',
      fallbackModel: 'fallback',
    );

AgentGraph _graph() {
  final primary = _entry(_agent('primary', subagents: ['runner']));
  final runner = _entry(_agent('runner', mode: AgentMode.subagent));
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
}) => AgentDefinition(
  id: id,
  name: id,
  description: id,
  mode: mode,
  prompt: 'prompt',
  subagents: subagents,
);

class _Streamer implements SubagentCompletionStreamer {
  _Streamer(this.events);

  final List<ChatStreamEvent> events;
  int calls = 0;

  @override
  Stream<ChatStreamEvent> streamSubagentCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
  }) {
    calls++;
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
