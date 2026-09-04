import 'dart:convert';

import 'chat_message.dart';
import 'conversation.dart';

enum ToolExecutionStatus { running, completed, failed }

class ToolExecution {
  const ToolExecution({
    required this.assistantMessageId,
    required this.callIndex,
    required this.callOccurrence,
    required this.call,
    required this.status,
    this.result,
    this.error,
    this.awaitingConfirmation = false,
  });

  final String assistantMessageId;
  final int callIndex;
  final int callOccurrence;
  final ChatToolCall call;
  final ToolExecutionStatus status;
  final ChatMessage? result;
  final String? error;
  final bool awaitingConfirmation;
}

List<ToolExecution> projectToolExecutions(Conversation? conversation) {
  if (conversation == null) return const [];
  final executions = <ToolExecution>[];
  for (
    var assistantIndex = 0;
    assistantIndex < conversation.messages.length;
    assistantIndex++
  ) {
    final assistant = conversation.messages[assistantIndex];
    if (assistant.role != ChatRole.assistant || assistant.toolCalls.isEmpty) {
      continue;
    }
    final results = <ChatMessage>[];
    for (
      var index = assistantIndex + 1;
      index < conversation.messages.length;
      index++
    ) {
      final candidate = conversation.messages[index];
      if (candidate.role == ChatRole.assistant) break;
      if (candidate.role == ChatRole.tool) results.add(candidate);
    }
    for (final indexedCall in assistant.toolCalls.indexed) {
      final call = indexedCall.$2;
      final occurrence = assistant.toolCalls
          .take(indexedCall.$1)
          .where((candidate) => candidate.id == call.id)
          .length;
      final matches = results
          .where(
            (result) =>
                result.toolCallIndex == indexedCall.$1 ||
                (result.toolCallIndex == null && result.toolCallId == call.id),
          )
          .toList(growable: false);
      final result = occurrence < matches.length ? matches[occurrence] : null;
      final error = result == null ? null : toolResultError(result.content);
      final proposal = conversation.pendingMemoryProposal;
      final toolProposal = conversation.pendingToolProposal;
      final workspaceProposal = conversation.pendingWorkspaceProposal;
      final awaitingConfirmation =
          proposal?.assistantMessageId == assistant.id &&
              proposal?.toolCallId == call.id &&
              proposal?.callOccurrence == occurrence ||
          (toolProposal?.assistantMessageId == assistant.id &&
              toolProposal?.call.id == call.id &&
              toolProposal?.callOccurrence == occurrence) ||
          (workspaceProposal?.assistantMessageId == assistant.id &&
              workspaceProposal?.toolCallId == call.id &&
              workspaceProposal?.callOccurrence == occurrence);
      final active =
          assistant.status == ChatMessageStatus.pending ||
          assistant.status == ChatMessageStatus.streaming;
      executions.add(
        ToolExecution(
          assistantMessageId: assistant.id,
          callIndex: indexedCall.$1,
          callOccurrence: occurrence,
          call: call,
          status: result == null && (active || awaitingConfirmation)
              ? ToolExecutionStatus.running
              : error != null || result == null
              ? ToolExecutionStatus.failed
              : ToolExecutionStatus.completed,
          result: result,
          error:
              error ??
              (result == null && !active && !awaitingConfirmation
                  ? 'Execution was interrupted'
                  : null),
          awaitingConfirmation: awaitingConfirmation,
        ),
      );
    }
  }
  return List.unmodifiable(executions);
}

String? toolResultError(String content) {
  try {
    final value = jsonDecode(content);
    if (value is Map && value['ok'] == false) {
      final error = value['error']?.toString();
      if (error != null && error.isNotEmpty) {
        return error.length <= 512 ? error : error.substring(0, 512);
      }
      final code = value['error_code']?.toString();
      if (code != null && code.isNotEmpty) {
        return code.length <= 128 ? code : code.substring(0, 128);
      }
      return 'Tool execution failed';
    }
  } on FormatException {
    // Plain text is a valid tool result.
  }
  return null;
}
