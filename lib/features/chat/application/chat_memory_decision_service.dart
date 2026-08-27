import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/conversation.dart';
import '../domain/pending_memory_proposal.dart';
import 'chat_lifecycle_service.dart';

typedef MemoryDecisionServicesResolver =
    MemoryDecisionServices Function(
      String conversationId,
      PendingMemoryProposal proposal,
    );

class ChatMemoryDecisionAction {
  const ChatMemoryDecisionAction({this.errorMessage});

  final String? errorMessage;
}

/// Executes memory decisions without owning or mutating canonical chat state.
class ChatMemoryDecisionService {
  const ChatMemoryDecisionService({
    required AppLogger logger,
    required MemoryDecisionServicesResolver servicesForDecision,
    required Conversation? Function(String conversationId) conversationById,
    required void Function(
      String conversationId,
      PendingMemoryProposal proposal,
    )
    completeDecision,
    required Future<void> Function() refreshPersonas,
  }) : _logger = logger,
       _servicesForDecision = servicesForDecision,
       _conversationById = conversationById,
       _completeDecision = completeDecision,
       _refreshPersonas = refreshPersonas;

  final AppLogger _logger;
  final MemoryDecisionServicesResolver _servicesForDecision;
  final Conversation? Function(String conversationId) _conversationById;
  final void Function(String conversationId, PendingMemoryProposal proposal)
  _completeDecision;
  final Future<void> Function() _refreshPersonas;

  Future<ChatMemoryDecisionAction> confirm({
    required Conversation? conversation,
    required PendingMemoryProposal? proposal,
  }) async {
    if (conversation == null || proposal == null) {
      _logger.log(
        event: 'memory.confirm_click',
        level: AppLogLevel.warning,
        status: 'unavailable',
      );
      return ChatMemoryDecisionAction(
        errorMessage: 'chat.memoryConfirmGone'.tr(),
      );
    }
    final conversationId = conversation.id;
    final toolCallId = proposal.toolCallId;
    final stopwatch = Stopwatch()..start();
    _logger.log(
      event: 'memory.confirm_click',
      conversationId: conversationId,
      toolCallId: toolCallId,
      fileName: proposal.fileName,
      status: 'started',
    );
    try {
      final decision = _servicesForDecision(conversationId, proposal);
      final updates = decision.updates;
      _logger.log(
        event: 'memory.provider_availability',
        conversationId: conversationId,
        toolCallId: toolCallId,
        status: updates == null ? 'unavailable' : 'available',
        level: updates == null ? AppLogLevel.warning : AppLogLevel.debug,
      );
      if (updates == null) {
        _logger.log(
          event: 'memory.confirm',
          level: AppLogLevel.warning,
          conversationId: conversationId,
          toolCallId: toolCallId,
          fileName: proposal.fileName,
          status: 'unavailable',
          duration: stopwatch.elapsed,
        );
        return ChatMemoryDecisionAction(
          errorMessage: 'chat.memoryUnavailable'.tr(),
        );
      }
      final runtime = decision.runtime;
      if (runtime == null) {
        throw StateError('Memory proposal runtime is unavailable');
      }
      await runtime.revalidateMemoryProposal(proposal);
      _requireCurrentProposal(conversationId, proposal, 'during confirmation');
      final result = await updates.applyPersisted(
        fileName: proposal.fileName,
        proposedContent: proposal.proposedContent,
        diff: proposal.diff,
        confirmationToken: proposal.confirmationToken,
        version: proposal.version,
        createdAt: proposal.createdAt,
      );
      if (proposal.requiredToolPermission == 'delete_persona') {
        await _refreshPersonas();
      }
      _requireCurrentProposal(conversationId, proposal, 'after apply');
      await _continueAfterDecision(
        conversationId,
        proposal,
        jsonEncode({
          'ok': true,
          'file_name': result.fileName,
          'previous_version': result.previousVersion,
          'version': result.version,
        }),
        decision,
      );
      _logger.log(
        event: 'memory.confirm',
        conversationId: conversationId,
        toolCallId: toolCallId,
        fileName: proposal.fileName,
        status: 'succeeded',
        duration: stopwatch.elapsed,
      );
      return const ChatMemoryDecisionAction();
    } on Object catch (error) {
      _logger.log(
        event: 'memory.confirm',
        level: AppLogLevel.error,
        conversationId: conversationId,
        toolCallId: toolCallId,
        fileName: proposal.fileName,
        status: 'failed',
        error: error,
        duration: stopwatch.elapsed,
      );
      return ChatMemoryDecisionAction(
        errorMessage: 'chat.memoryConfirmError'.tr(),
      );
    }
  }

  Future<ChatMemoryDecisionAction> reject({
    required Conversation conversation,
    required PendingMemoryProposal proposal,
  }) async {
    final decision = _servicesForDecision(conversation.id, proposal);
    await _continueAfterDecision(
      conversation.id,
      proposal,
      jsonEncode({'ok': false, 'rejected': true, 'reason': 'User rejected'}),
      decision,
    );
    await decision.updates?.revokeProposal(proposal.confirmationToken);
    return const ChatMemoryDecisionAction();
  }

  PendingMemoryProposal _requireCurrentProposal(
    String conversationId,
    PendingMemoryProposal expected,
    String phase,
  ) {
    final current = _conversationById(conversationId)?.pendingMemoryProposal;
    if (current == null || !expected.hasSameIdentity(current)) {
      throw StateError('Memory proposal changed $phase');
    }
    return current;
  }

  Future<void> _continueAfterDecision(
    String conversationId,
    PendingMemoryProposal expected,
    String result,
    MemoryDecisionServices decision,
  ) async {
    final conversation = _conversationById(conversationId);
    final proposal = conversation?.pendingMemoryProposal;
    if (conversation == null ||
        proposal == null ||
        !expected.hasSameIdentity(proposal)) {
      throw StateError('Pending memory proposal is no longer available');
    }
    _logger.log(
      event: 'memory.follow_up',
      conversationId: conversationId,
      toolCallId: proposal.toolCallId,
      status: 'started',
    );
    try {
      await decision.coordinator.continueAfterMemoryDecision(
        conversation: conversation,
        proposal: proposal,
        toolResult: result,
      );
      _completeDecision(conversationId, proposal);
      _logger.log(
        event: 'memory.tool_result_persistence',
        conversationId: conversationId,
        toolCallId: proposal.toolCallId,
        status: 'succeeded',
      );
    } on Object catch (error) {
      _logger.log(
        event: 'memory.follow_up',
        level: AppLogLevel.error,
        conversationId: conversationId,
        toolCallId: proposal.toolCallId,
        status: 'failed',
        error: error,
      );
      rethrow;
    }
  }
}
