import 'package:dio/dio.dart';

import '../data/chat_repository.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';

class ChatStreamRequest {
  const ChatStreamRequest({
    required this.conversationId,
    required this.requestMessageId,
    required this.assistantMessageId,
    required this.modelId,
    required this.history,
  });

  final String conversationId;
  final String requestMessageId;
  final String assistantMessageId;
  final String modelId;
  final List<ChatMessage> history;
}

({Conversation conversation, ChatStreamRequest request})?
prepareInterruptedRetry(Conversation conversation, DateTime now) {
  final requestId = conversation.pendingRequestMessageId;
  if (requestId == null) return null;
  final requestMessage = conversation.messages
      .where((message) => message.id == requestId)
      .firstOrNull;
  if (requestMessage == null || requestMessage.role != ChatRole.user) {
    return null;
  }

  final assistantId = '${now.microsecondsSinceEpoch}-assistant';
  final updated = conversation.copyWith(
    updatedAt: now,
    messages: [
      ...conversation.messages,
      ChatMessage(
        id: assistantId,
        role: ChatRole.assistant,
        content: '',
        createdAt: now,
        status: ChatMessageStatus.pending,
      ),
    ],
  );
  return (
    conversation: updated,
    request: buildChatStreamRequest(updated, requestId, assistantId),
  );
}

ChatStreamRequest buildChatStreamRequest(
  Conversation conversation,
  String requestId,
  String assistantId,
) => ChatStreamRequest(
  conversationId: conversation.id,
  requestMessageId: requestId,
  assistantMessageId: assistantId,
  modelId: conversation.modelId,
  history: conversation.messages
      .where((message) => message.id != assistantId)
      .where(
        (message) =>
            message.role != ChatRole.assistant ||
            (message.status != ChatMessageStatus.interrupted &&
                message.status != ChatMessageStatus.failed),
      )
      .toList(growable: false),
);

class ChatStreamingCoordinator {
  ChatStreamingCoordinator({
    required ChatCompletionStreamer streamer,
    required Conversation? Function(String id) conversationById,
    required Future<void> Function(Conversation conversation) persistAndPublish,
    required void Function(String message) publishError,
  }) : _streamer = streamer,
       _conversationById = conversationById,
       _persistAndPublish = persistAndPublish,
       _publishError = publishError;

  final ChatCompletionStreamer _streamer;
  final Conversation? Function(String id) _conversationById;
  final Future<void> Function(Conversation conversation) _persistAndPublish;
  final void Function(String message) _publishError;

  ChatStreamRequest? _activeRequest;
  CancelToken? _cancelToken;
  Future<void>? _running;

  Future<void> run(ChatStreamRequest request) {
    if (_running != null) {
      throw StateError('A chat request is already running');
    }
    final operation = _run(request);
    _running = operation;
    return operation;
  }

  void cancel(String conversationId) {
    if (_activeRequest?.conversationId == conversationId) {
      _cancelToken?.cancel('Cancelled by user');
    }
  }

  Future<void> cancelAndWait(String conversationId) async {
    if (_activeRequest?.conversationId != conversationId) return;
    _cancelToken?.cancel('Conversation deleted');
    await _running;
  }

  Future<void> _run(ChatStreamRequest request) async {
    final cancelToken = CancelToken();
    _activeRequest = request;
    _cancelToken = cancelToken;
    var terminalSeen = false;
    try {
      await for (final event in _streamer.streamCompletion(
        model: request.modelId,
        messages: request.history,
        cancelToken: cancelToken,
      )) {
        final latest = _conversationById(request.conversationId);
        if (latest == null) {
          cancelToken.cancel('Conversation deleted');
          return;
        }
        terminalSeen = terminalSeen || event.isTerminal;
        final updated = latest.copyWith(
          updatedAt: DateTime.now(),
          usage: event.usage == null
              ? null
              : ConversationUsage.fromChatUsage(event.usage!),
          messages: latest.messages
              .map(
                (message) => message.id == request.assistantMessageId
                    ? message.copyWith(
                        content: '${message.content}${event.delta}',
                        status: ChatMessageStatus.streaming,
                      )
                    : message,
              )
              .toList(),
        );
        await _persistAndPublish(updated);
      }
      if (cancelToken.isCancelled) {
        await _finish(request, ChatMessageStatus.interrupted);
      } else if (terminalSeen) {
        await _finish(request, ChatMessageStatus.complete);
      } else {
        await _interruptWithError(
          request,
          'The response stream closed before completion. Retry the interrupted response.',
        );
      }
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        await _finish(request, ChatMessageStatus.interrupted);
      } else {
        await _interruptWithError(request, _friendlyError(error));
      }
    } on FormatException catch (error) {
      await _interruptWithError(request, error.message);
    } finally {
      if (identical(_activeRequest, request)) {
        _activeRequest = null;
        _cancelToken = null;
        _running = null;
      }
    }
  }

  Future<void> _interruptWithError(
    ChatStreamRequest request,
    String message,
  ) async {
    await _finish(request, ChatMessageStatus.interrupted);
    _publishError(message);
  }

  Future<void> _finish(
    ChatStreamRequest request,
    ChatMessageStatus status,
  ) async {
    final conversation = _conversationById(request.conversationId);
    if (conversation == null) return;
    final updated = conversation.copyWith(
      updatedAt: DateTime.now(),
      clearPendingRequest: status == ChatMessageStatus.complete,
      messages: conversation.messages
          .map(
            (message) => message.id == request.assistantMessageId
                ? message.copyWith(status: status)
                : message,
          )
          .toList(),
    );
    await _persistAndPublish(updated);
  }

  static String _friendlyError(DioException error) => switch (error.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout =>
      'The endpoint timed out. Check the address and try again.',
    DioExceptionType.connectionError =>
      'Could not connect to the endpoint. Check the network and address.',
    DioExceptionType.badResponse =>
      'Endpoint returned HTTP ${error.response?.statusCode}. Check the model and API key.',
    _ => 'The request failed. You can retry the interrupted response.',
  };
}
