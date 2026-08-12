import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../domain/delegation.dart';
import 'subagent_executor.dart';

part 'delegation_controller.g.dart';

enum DelegationExecutionStatus { idle, running, completed, failed, cancelled }

class DelegationState {
  const DelegationState({
    this.status = DelegationExecutionStatus.idle,
    this.result,
    this.error,
  });

  final DelegationExecutionStatus status;
  final DelegationResult? result;
  final String? error;

  bool get isRunning => status == DelegationExecutionStatus.running;
}

@riverpod
class DelegationController extends _$DelegationController {
  CancelToken? _cancelToken;

  @override
  DelegationState build() {
    ref.onDispose(() => _cancelToken?.cancel('Delegation controller disposed'));
    return const DelegationState();
  }

  Future<void> execute({
    required String parentConversationId,
    required String parentRequestId,
    required String subagentId,
    required String task,
    required String context,
    required String fallbackModel,
  }) async {
    if (state.isRunning) return;

    final DelegationRequest request;
    try {
      request = DelegationRequest(
        parentConversationId: parentConversationId.trim(),
        parentRequestId: parentRequestId.trim(),
        subagentId: subagentId,
        task: task.trim(),
        context: context.trim(),
      );
    } on ArgumentError catch (error) {
      state = DelegationState(
        status: DelegationExecutionStatus.failed,
        error: error.message?.toString() ?? '$error',
      );
      return;
    }

    final token = CancelToken();
    _cancelToken = token;
    state = const DelegationState(status: DelegationExecutionStatus.running);
    try {
      final executor = await ref.read(subagentExecutorProvider.future);
      final result = await executor.execute(
        request: request,
        fallbackModel: fallbackModel,
        cancelToken: token,
      );
      if (_cancelToken != token) return;
      state = DelegationState(
        status: switch (result.status) {
          DelegationStatus.completed => DelegationExecutionStatus.completed,
          DelegationStatus.failed => DelegationExecutionStatus.failed,
          DelegationStatus.cancelled => DelegationExecutionStatus.cancelled,
        },
        result: result,
        error: result.error,
      );
    } on Object catch (error) {
      if (_cancelToken != token) return;
      state = DelegationState(
        status: token.isCancelled
            ? DelegationExecutionStatus.cancelled
            : DelegationExecutionStatus.failed,
        error: token.isCancelled ? 'Delegation cancelled' : '$error',
      );
    } finally {
      if (_cancelToken == token) _cancelToken = null;
    }
  }

  void cancel() {
    _cancelToken?.cancel('Delegation cancelled');
  }
}
