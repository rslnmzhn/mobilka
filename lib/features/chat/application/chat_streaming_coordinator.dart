import 'package:dio/dio.dart';
import '../../../core/logging/app_logger.dart';
export 'chat_stream_request.dart';
import 'background_task_bridge.dart';
import 'chat_background_lease.dart';
import 'chat_stream_finalizer.dart';
import 'chat_stream_request.dart';
import 'chat_stream_support.dart';
import 'chat_request_run_session.dart';
import 'chat_tool_executor.dart';
import 'chat_tool_runtime.dart';
import 'pending_workspace_binding_store.dart';
import 'conversation_mutation.dart';
import 'request_tool_security_state.dart';
import 'memory_decision_continuation.dart';
import '../../../features/memory/application/instant_memory_writer.dart';
import '../../../features/memory/application/persona_registry.dart';
import '../../../features/memory/application/workspace_paths.dart';
import '../data/chat_repository.dart';
import '../../settings/data/settings_repository.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import '../domain/chat_tool.dart';
import '../domain/pending_memory_proposal.dart';
import '../domain/request_execution_ledger.dart';

class ChatStreamingCoordinator {
  ChatStreamingCoordinator({
    required ChatCompletionStreamer streamer,
    required Conversation? Function(String id) conversationById,
    required PersistConversationMutation persistMutation,
    required void Function(String message) publishError,
    ChatToolRuntime? toolRuntime,
    BackgroundTaskBridge backgroundTasks = const NoopBackgroundTaskBridge(),
    InstantMemoryWriter? instantMemoryWriter,
    PersonaRegistryAdapter? personaRegistry,
    void Function(String event)? onTransientRetry,
    AppLogger? logger,
    PendingWorkspaceBindingStore? workspaceBindings,
    void Function(ChatStreamRequest request, String assistantText)?
    onFinalSuccess,
  }) : _streamer = streamer,
       _conversationById = conversationById,
       _persistMutation = persistMutation,
       _publishError = publishError,
       _toolRuntime = toolRuntime,
       _backgroundTasks = backgroundTasks,
       _instantMemoryWriter = instantMemoryWriter,
       _personaRegistry = personaRegistry,
       _onTransientRetry = onTransientRetry,
       _logger = logger,
       _workspaceBindings = workspaceBindings ?? PendingWorkspaceBindingStore(),
       _ownsWorkspaceBindings = workspaceBindings == null,
       _onFinalSuccess = onFinalSuccess;

  final ChatCompletionStreamer _streamer;
  final Conversation? Function(String id) _conversationById;
  final PersistConversationMutation _persistMutation;
  final void Function(String message) _publishError;
  final ChatToolRuntime? _toolRuntime;
  final InstantMemoryWriter? _instantMemoryWriter;
  final PersonaRegistryAdapter? _personaRegistry;
  final void Function(String event)? _onTransientRetry;
  final AppLogger? _logger;
  late final ChatBackgroundLease _backgroundLease = ChatBackgroundLease(
    bridge: _backgroundTasks,
    publishUnavailable: () => _publishError('backgroundUnavailable'),
    logger: _logger,
  );
  late final ChatStreamFinalizer _finalizer = ChatStreamFinalizer(
    persistMutation: _persistMutation,
    publishError: _publishError,
  );
  final BackgroundTaskBridge _backgroundTasks;
  ChatToolExecutor? _toolExecutorFor(ChatStreamRequest request) =>
      _toolRuntime == null
      ? null
      : ChatToolExecutor(
          runtime: _toolRuntime,
          conversationById: _conversationById,
          persistMutation: _persistMutation,
          instantMemoryWriter: _instantMemoryWriter,
          personaRegistry: _personaRegistry,
          logger: _logger,
          onPendingMemoryProposal: (proposal) {
            final binding = request.workspaceBinding;
            if (binding != null) {
              _workspaceBindings.retain(request, proposal, binding);
            }
          },
        );

  static const maxTransientRetries = 1;

  ChatStreamRequest? _activeRequest;
  CancelToken? _cancelToken;
  Future<void>? _running;
  final Set<String> _memoryDecisions = {};
  RequestToolSecurityState? _requestSecurity;
  final PendingWorkspaceBindingStore _workspaceBindings;
  final bool _ownsWorkspaceBindings;
  late final void Function(ChatStreamRequest request, String assistantText)?
  _onFinalSuccess;
  Future<void> run(ChatStreamRequest request) {
    if (_running != null) {
      throw StateError('A chat request is already running');
    }
    final operation = _run(request);
    _running = operation;
    return operation;
  }

  Future<void> continueAfterMemoryDecision({
    required Conversation conversation,
    required PendingMemoryProposal proposal,
    required String toolResult,
  }) async {
    final decisionId =
        '${conversation.id}:${conversation.pendingRequestMessageId}:${proposal.assistantMessageId}:'
        '${proposal.toolCallId}:${proposal.callOccurrence}';
    if (!_memoryDecisions.add(decisionId)) return;
    if (_running != null) {
      _memoryDecisions.remove(decisionId);
      throw StateError('A chat request is already running');
    }
    try {
      await MemoryDecisionContinuation(
        conversationById: _conversationById,
        persistMutation: _persistMutation,
        workspaceBindings: _workspaceBindings,
        run: run,
      ).continueRequest(
        conversation: conversation,
        proposal: proposal,
        toolResult: toolResult,
      );
    } on Object {
      _memoryDecisions.remove(decisionId);
      rethrow;
    }
  }

  void cancel(String conversationId) {
    if (_activeRequest?.conversationId == conversationId) {
      _cancelToken?.cancel('Cancelled by user');
    }
  }

  Future<void> cancelAndWait(String conversationId) async {
    if (_activeRequest?.conversationId == conversationId) {
      _cancelToken?.cancel('Conversation deleted');
      await _running;
    }
    forgetConversation(conversationId);
  }

  void forgetConversation(String conversationId) {
    _workspaceBindings.forgetConversation(conversationId);
    _memoryDecisions.removeWhere(
      (decision) => decision.startsWith('$conversationId:'),
    );
    if (_requestSecurity?.conversationId == conversationId) {
      _requestSecurity = null;
    }
  }

  WorkspaceBinding? retainedWorkspaceBindingForRetry(
    String conversationId,
    String requestMessageId,
  ) => _workspaceBindings.resolveForRetry(conversationId, requestMessageId);

  void dispose() {
    _cancelToken?.cancel('Coordinator disposed');
    if (_ownsWorkspaceBindings) _workspaceBindings.reset();
    _memoryDecisions.clear();
    _requestSecurity = null;
  }

  Future<void> _run(ChatStreamRequest request) async {
    _requestSecurity = RequestToolSecurityState(
      conversationId: request.conversationId,
      requestId: request.requestMessageId,
      readLedger: () => _requestLedger(request),
      appendLedgerEntry: (entry) => _appendLedgerEntry(request, entry),
    );
    final cancelToken = CancelToken();
    _activeRequest = request;
    _cancelToken = cancelToken;
    var phase = 'acquire_background';
    try {
      await _backgroundLease.acquire(request);
      phase = 'resolve_tools';
      final tools =
          await _toolRuntime?.availableTools(request.allowedTools) ??
          const <ChatToolDefinition>[];
      phase = 'stream_request';
      await ChatRequestRunSession(
        request: request,
        streamer: _streamer,
        conversationById: _conversationById,
        persistMutation: _persistMutation,
        finalizer: _finalizer,
        security: _requestSecurity!,
        cancelToken: cancelToken,
        tools: tools,
        executeTools: (assistant, calls) =>
            _executeTools(request, assistant, calls),
        appendPendingAssistant: (assistant) =>
            _appendPendingAssistant(request, assistant),
        toolRuntime: _toolRuntime,
        onTransientRetry: _onTransientRetry,
        onFinalSuccess: _onFinalSuccess,
        logger: _logger,
      ).run();
    } on Object catch (error, stackTrace) {
      final preparation = error is ChatPreparationException ? error : null;
      final cause = preparation?.cause ?? error;
      _logRequestFailure(
        request,
        phase: preparation == null ? phase : '$phase.${preparation.phase}',
        error: cause,
        stackTrace: preparation?.causeStackTrace ?? stackTrace,
      );
      await _handleFailure(request, cause);
    } finally {
      await _cleanup(request);
    }
  }

  RequestExecutionLedger _requestLedger(ChatStreamRequest request) {
    final ledger = _conversationById(
      request.conversationId,
    )?.requestExecutionLedger;
    if (ledger?.requestId == request.requestMessageId) return ledger!;
    return RequestExecutionLedger(
      requestId: request.requestMessageId,
      entries: const [],
    );
  }

  Future<RequestExecutionLedger> _appendLedgerEntry(
    ChatStreamRequest request,
    ToolExecutionLedgerEntry entry,
  ) async {
    final saved = await _persistMutation(request.conversationId, (latest) {
      if (latest.pendingRequestMessageId != request.requestMessageId) {
        return null;
      }
      final current = latest.requestExecutionLedger;
      final ledger = current?.requestId == request.requestMessageId
          ? current!
          : RequestExecutionLedger(
              requestId: request.requestMessageId,
              entries: const [],
            );
      return latest.copyWith(requestExecutionLedger: ledger.append(entry));
    });
    if (saved == null) throw StateError('Request ledger identity changed');
    return saved.requestExecutionLedger!;
  }

  Future<void> _handleFailure(ChatStreamRequest request, Object error) async {
    if (error is DioException) {
      if (CancelToken.isCancel(error)) {
        await _finalizer.finish(request, ChatMessageStatus.interrupted);
      } else {
        await _finalizer.interrupt(request, friendlyChatError(error));
      }
      return;
    }
    if (error is FormatException) {
      await _finalizer.interrupt(request, error.message);
      return;
    }
    if (error is SettingsSecretUnavailableException) {
      await _finalizer.interrupt(request, 'chat.settingsSecretUnavailable');
      return;
    }
    await _finalizer.interrupt(
      request,
      'The request failed unexpectedly. Please retry.',
    );
  }

  void _logRequestFailure(
    ChatStreamRequest request, {
    required String phase,
    required Object error,
    required StackTrace stackTrace,
  }) {
    _logger?.log(
      event: 'chat.streaming',
      level: AppLogLevel.error,
      conversationId: request.conversationId,
      status: 'failed',
      phase: phase,
      error: error,
      errorCode: switch (error) {
        SettingsSecretUnavailableException() => 'secure_storage_unavailable',
        UnsupportedError() => 'unsupported_operation',
        DioException() => 'network_error',
        FormatException() => 'invalid_data',
        _ => 'unexpected_error',
      },
      stackTrace: stackTrace,
    );
  }

  Future<void> _cleanup(ChatStreamRequest request) async {
    final latest = _conversationById(request.conversationId);
    if (latest == null || latest.pendingRequestMessageId == null) {
      _workspaceBindings.cleanupTerminal(
        request.conversationId,
        request.requestMessageId,
      );
    }
    await _backgroundLease.release(request);
    if (!identical(_activeRequest, request)) return;
    _activeRequest = null;
    _cancelToken = null;
    _running = null;
  }

  Future<bool> _executeTools(
    ChatStreamRequest request,
    String assistantId,
    List<ChatToolCall> calls,
  ) async {
    final executor = _toolExecutorFor(request);
    if (executor == null || calls.isEmpty) {
      throw const FormatException('Tool call response has no executable calls');
    }
    final result = await executor.execute(
      request,
      assistantId,
      calls,
      cancellation: _DioToolCancellation(_cancelToken!),
      securityState: _requestSecurity!,
    );
    return result;
  }

  Future<void> _appendPendingAssistant(
    ChatStreamRequest request,
    String assistantId,
  ) async {
    await _persistMutation(request.conversationId, (latest) {
      if (latest.pendingRequestMessageId != request.requestMessageId ||
          latest.messages.any((message) => message.id == assistantId)) {
        return null;
      }
      return latest.copyWith(
        updatedAt: DateTime.now(),
        messages: [
          ...latest.messages,
          ChatMessage(
            id: assistantId,
            role: ChatRole.assistant,
            content: '',
            createdAt: DateTime.now(),
            status: ChatMessageStatus.pending,
          ),
        ],
      );
    });
  }
}

class _DioToolCancellation implements ChatToolCancellation {
  const _DioToolCancellation(this.token);
  final CancelToken token;

  @override
  bool get isCancelled => token.isCancelled;

  @override
  Future<void> get whenCancelled async {
    await token.whenCancel;
  }
}
