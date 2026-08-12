import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/data/chat_repository.dart';
import '../../chat/domain/chat_message.dart';
import '../domain/agent_graph.dart';
import '../domain/delegation.dart';
import 'agents_controller.dart';

final agentGraphProvider = FutureProvider.autoDispose<AgentGraph>((ref) async {
  final catalog = await ref.watch(agentsControllerProvider.future);
  return const AgentGraphResolver().resolve(catalog);
});

final subagentExecutorProvider = FutureProvider.autoDispose<SubagentExecutor>((
  ref,
) async {
  final graph = await ref.watch(agentGraphProvider.future);
  return SubagentExecutor(
    streamer: ref.watch(chatRepositoryProvider),
    graph: graph,
  );
});

class SubagentExecutor {
  const SubagentExecutor({required this.streamer, required this.graph});

  final SubagentCompletionStreamer streamer;
  final AgentGraph graph;

  Future<DelegationResult> execute({
    required DelegationRequest request,
    required String fallbackModel,
    CancelToken? cancelToken,
  }) async {
    final primary = graph.selectedPrimary;
    final subagent = graph.selectedAvailableSubagents
        .where((entry) => entry.definition.id == request.subagentId)
        .firstOrNull;
    if (primary == null || subagent == null) {
      return _result(
        request,
        DelegationStatus.failed,
        error: 'Subagent is not available to the selected primary agent',
      );
    }
    if (fallbackModel.trim().isEmpty &&
        subagent.definition.modelPreference == null) {
      return _result(
        request,
        DelegationStatus.failed,
        error: 'No model is available for delegation',
      );
    }

    final token = cancelToken ?? CancelToken();
    final content = StringBuffer();
    var terminalSeen = false;
    try {
      await for (final event in streamer.streamSubagentCompletion(
        model: subagent.definition.modelPreference ?? fallbackModel,
        messages: _messages(request, subagent.definition.prompt),
        cancelToken: token,
      )) {
        if (content.length + event.delta.length >
            DelegationResult.maxContentCharacters) {
          token.cancel('Delegation result exceeded the size limit');
          return _result(
            request,
            DelegationStatus.failed,
            content: content.toString(),
            error: 'Delegation result exceeded the size limit',
          );
        }
        content.write(event.delta);
        terminalSeen = terminalSeen || event.isTerminal;
      }
      if (token.isCancelled) {
        return _result(
          request,
          DelegationStatus.cancelled,
          content: content.toString(),
          error: 'Delegation cancelled',
        );
      }
      if (!terminalSeen) {
        return _result(
          request,
          DelegationStatus.failed,
          content: content.toString(),
          error: 'Delegation stream closed before completion',
        );
      }
      return _result(
        request,
        DelegationStatus.completed,
        content: content.toString(),
      );
    } on DioException catch (error) {
      final cancelled = CancelToken.isCancel(error) || token.isCancelled;
      return _result(
        request,
        cancelled ? DelegationStatus.cancelled : DelegationStatus.failed,
        content: content.toString(),
        error: cancelled
            ? 'Delegation cancelled'
            : _boundedError(error.message ?? '$error'),
      );
    } on Object catch (error) {
      return _result(
        request,
        DelegationStatus.failed,
        content: content.toString(),
        error: _boundedError('$error'),
      );
    }
  }

  List<ChatMessage> _messages(DelegationRequest request, String prompt) {
    final context = request.context.trim();
    return List.unmodifiable([
      ChatMessage(
        id: '${request.parentRequestId}-subagent-system',
        role: ChatRole.system,
        content: prompt,
        createdAt: DateTime.now(),
      ),
      ChatMessage(
        id: '${request.parentRequestId}-subagent-task',
        role: ChatRole.user,
        content: context.isEmpty
            ? request.task
            : 'Context:\n$context\n\nTask:\n${request.task}',
        createdAt: DateTime.now(),
      ),
    ]);
  }

  DelegationResult _result(
    DelegationRequest request,
    DelegationStatus status, {
    String content = '',
    String? error,
  }) => DelegationResult(
    parentConversationId: request.parentConversationId,
    parentRequestId: request.parentRequestId,
    subagentId: request.subagentId,
    status: status,
    content: content,
    error: error,
  );

  String _boundedError(String value) =>
      value.length <= DelegationResult.maxErrorCharacters
      ? value
      : value.substring(0, DelegationResult.maxErrorCharacters);
}
