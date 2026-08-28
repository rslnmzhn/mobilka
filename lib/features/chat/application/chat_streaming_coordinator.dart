import 'package:dio/dio.dart';
import '../../../core/logging/app_logger.dart';
export 'chat_stream_request.dart';
import 'background_task_bridge.dart';
import 'chat_background_lease.dart';
import 'chat_stream_finalizer.dart';
import 'chat_stream_request.dart';
import 'chat_stream_support.dart';
import 'chat_tool_executor.dart';
import 'chat_tool_runtime.dart';
import 'fallback_tool_call_parser.dart';
import 'pending_workspace_binding_store.dart';
import 'conversation_mutation.dart';
import 'request_tool_security_state.dart';
import '../../../features/memory/application/instant_memory_writer.dart';
import '../../../features/memory/application/persona_registry.dart';
import '../../../features/memory/application/workspace_paths.dart';
import '../data/chat_repository.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import '../domain/chat_tool.dart';
import '../domain/pending_memory_proposal.dart';

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
    final requestMessageId = conversation.pendingRequestMessageId;
    if (requestMessageId == null) return;
    final decisionId =
        '${conversation.id}:$requestMessageId:${proposal.assistantMessageId}:'
        '${proposal.toolCallId}:${proposal.callOccurrence}';
    if (!_memoryDecisions.add(decisionId)) return;
    final currentProposal = _conversationById(
      conversation.id,
    )?.pendingMemoryProposal;
    if (currentProposal?.toolCallId != proposal.toolCallId ||
        currentProposal?.assistantMessageId != proposal.assistantMessageId ||
        currentProposal?.callOccurrence != proposal.callOccurrence) {
      _memoryDecisions.remove(decisionId);
      return;
    }
    if (_running != null) {
      _memoryDecisions.remove(decisionId);
      throw StateError('A chat request is already running');
    }
    final now = DateTime.now();
    final assistantId = '${now.microsecondsSinceEpoch}-assistant';
    final toolResultMessage = ChatMessage(
      id: '${now.microsecondsSinceEpoch}-tool',
      role: ChatRole.tool,
      content: toolResult,
      createdAt: now,
      toolCallId: proposal.toolCallId,
    );
    final retainedBinding = _workspaceBindings.resolveForDecision(
      conversationId: conversation.id,
      requestMessageId: requestMessageId,
      proposal: proposal,
    );
    try {
      final updated = await _persistMutation(conversation.id, (latest) {
        final latestProposal = latest.pendingMemoryProposal;
        if (latest.pendingRequestMessageId != requestMessageId ||
            latestProposal == null ||
            !latestProposal.hasSameIdentity(proposal)) {
          return null;
        }
        final latestMessages = [...latest.messages];
        final proposalIndex = latestMessages.indexWhere(
          (message) => message.id == proposal.assistantMessageId,
        );
        final insertion = proposalIndex < 0
            ? latestMessages.length
            : proposalIndex + 1 + proposal.callOccurrence;
        latestMessages.insert(
          insertion.clamp(0, latestMessages.length),
          toolResultMessage,
        );
        latestMessages.add(
          ChatMessage(
            id: assistantId,
            role: ChatRole.assistant,
            content: '',
            createdAt: now,
            status: ChatMessageStatus.pending,
          ),
        );
        return latest.copyWith(
          updatedAt: now,
          clearPendingMemoryProposal: true,
          messages: latestMessages,
        );
      });
      if (updated == null) return;
      await run(
        buildChatStreamRequest(
          updated,
          updated.pendingRequestMessageId!,
          assistantId,
          selectedAgentId: proposal.selectedAgentId,
          allowedTools: proposal.allowedTools,
          workspaceBinding: retainedBinding,
        ),
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
    );
    final cancelToken = CancelToken();
    _activeRequest = request;
    _cancelToken = cancelToken;
    try {
      await _backgroundLease.acquire(request);
      var history = request.history;
      var assistantId = request.assistantMessageId;
      var toolRounds = 0;
      var transientRetriesLeft = maxTransientRetries;
      final tools =
          await _toolRuntime?.availableTools(request.allowedTools) ??
          const <ChatToolDefinition>[];
      while (true) {
        var terminalSeen = false;
        String? finishReason;
        var receivedAnyToken = false;
        var eventCount = 0;
        final buffers = <int, ToolCallBuffer>{};
        try {
          await for (final event in _streamer.streamCompletion(
            model: request.modelId,
            messages: history,
            cancelToken: cancelToken,
            tools: tools,
          )) {
            eventCount++;
            receivedAnyToken =
                receivedAnyToken ||
                event.delta.isNotEmpty ||
                event.reasoningDelta.isNotEmpty ||
                event.toolCallDeltas.isNotEmpty;
            final updated = await _persistMutation(request.conversationId, (
              latest,
            ) {
              if (latest.pendingRequestMessageId != request.requestMessageId) {
                return null;
              }
              return latest.copyWith(
                updatedAt: DateTime.now(),
                usage: event.usage == null
                    ? null
                    : ConversationUsage.fromChatUsage(event.usage!),
                messages: latest.messages
                    .map(
                      (message) => message.id == assistantId
                          ? message.copyWith(
                              content: '${message.content}${event.delta}',
                              reasoningContent:
                                  '${message.reasoningContent}'
                                  '${event.reasoningDelta}',
                              status: ChatMessageStatus.streaming,
                            )
                          : message,
                    )
                    .toList(),
              );
            });
            if (updated == null) {
              cancelToken.cancel('Conversation deleted');
              return;
            }
            for (final delta in event.toolCallDeltas) {
              buffers
                  .putIfAbsent(delta.index, ToolCallBuffer.new)
                  .append(delta);
            }
            terminalSeen = terminalSeen || event.isTerminal;
            finishReason = event.finishReason ?? finishReason;
          }
          if (terminalSeen && finishReason == 'tool_calls') {
            toolRounds++;
            if (toolRounds > 8) {
              throw const FormatException('Tool call round limit exceeded');
            }
            final ordered = buffers.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key));
            final shouldContinue = await _executeTools(
              request,
              assistantId,
              ordered.map((entry) => entry.value.build()).toList(),
            );
            if (!shouldContinue) return;
            final conversation = _conversationById(request.conversationId)!;
            history = conversation.messages
                .where(
                  (message) => message.status == ChatMessageStatus.complete,
                )
                .toList(growable: false);
            assistantId = '${request.assistantMessageId}-followup-$toolRounds';
            await _appendPendingAssistant(request, assistantId);
            continue;
          }
          if (terminalSeen && buffers.isEmpty) {
            final conversation = _conversationById(request.conversationId)!;
            final assistant = conversation.messages.firstWhere(
              (message) => message.id == assistantId,
            );
            final parsed = parseFallbackToolCalls(
              assistantText: assistant.content,
              requestMessageId: request.requestMessageId,
              previouslyPersistedCallIds: conversation.messages
                  .expand((message) => message.toolCalls)
                  .map((call) => call.id)
                  .toSet(),
            );
            if (parsed.visibleText != assistant.content) {
              await _persistMutation(request.conversationId, (latest) {
                if (latest.pendingRequestMessageId !=
                    request.requestMessageId) {
                  return latest;
                }
                return latest.copyWith(
                  updatedAt: DateTime.now(),
                  messages: latest.messages
                      .map(
                        (message) => message.id == assistantId
                            ? message.copyWith(content: parsed.visibleText)
                            : message,
                      )
                      .toList(),
                );
              });
            }
            if (parsed.calls.isNotEmpty) {
              toolRounds++;
              if (toolRounds > 8) {
                throw const FormatException('Tool call round limit exceeded');
              }
              final shouldContinue = await _executeTools(
                request,
                assistantId,
                parsed.calls,
              );
              if (!shouldContinue) return;
              final updated = _conversationById(request.conversationId)!;
              history = updated.messages
                  .where(
                    (message) => message.status == ChatMessageStatus.complete,
                  )
                  .toList(growable: false);
              assistantId =
                  '${request.assistantMessageId}-followup-$toolRounds';
              await _appendPendingAssistant(request, assistantId);
              continue;
            }
          }
        } on DioException catch (error) {
          final retryable =
              isTransientChatError(error) &&
              !receivedAnyToken &&
              !terminalSeen &&
              buffers.isEmpty &&
              transientRetriesLeft > 0;
          if (retryable) {
            transientRetriesLeft--;
            _onTransientRetry?.call('chat.transient_retry');
            await Future<void>.delayed(const Duration(seconds: 1));
            continue;
          }
          rethrow;
        }
        if (cancelToken.isCancelled) {
          await _finalizer.finish(request, ChatMessageStatus.interrupted);
        } else if (terminalSeen) {
          final finalized = await _finalizer.finish(
            request,
            ChatMessageStatus.complete,
          );
          if (!finalized) return;
          final completed = _conversationById(request.conversationId);
          final assistant = completed?.messages
              .where((message) => message.id == assistantId)
              .firstOrNull;
          if (assistant != null) {
            _onFinalSuccess?.call(request, assistant.content);
          }
        } else {
          await _finalizer.interrupt(
            request,
            'The response stream closed before completion. Retry the interrupted response.',
          );
        }
        _logger?.log(
          event: 'chat.stream_outcome',
          conversationId: request.conversationId,
          status: cancelToken.isCancelled
              ? 'cancelled'
              : (terminalSeen ? 'terminal' : 'interrupted'),
          terminalSeen: terminalSeen,
          receivedAnyToken: receivedAnyToken,
          eventCount: eventCount,
        );
        return;
      }
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        await _finalizer.finish(request, ChatMessageStatus.interrupted);
      } else {
        await _finalizer.interrupt(request, friendlyChatError(error));
      }
    } on FormatException catch (error) {
      await _finalizer.interrupt(request, error.message);
    } on Object catch (error) {
      _logger?.log(
        event: 'chat.streaming',
        level: AppLogLevel.error,
        conversationId: request.conversationId,
        status: 'failed',
        error: error,
      );
      await _finalizer.interrupt(
        request,
        'The request failed unexpectedly. Please retry.',
      );
    } finally {
      final latest = _conversationById(request.conversationId);
      if (latest == null || latest.pendingRequestMessageId == null) {
        _workspaceBindings.cleanupTerminal(
          request.conversationId,
          request.requestMessageId,
        );
      }
      await _backgroundLease.release(request);
      if (identical(_activeRequest, request)) {
        _activeRequest = null;
        _cancelToken = null;
        _running = null;
      }
    }
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
