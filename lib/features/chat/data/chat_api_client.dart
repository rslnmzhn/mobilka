import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/network/endpoint_policy.dart';
import '../domain/chat_message.dart';
import '../domain/chat_stream_event.dart';

class ChatApiClient {
  ChatApiClient(this._dio);

  final Dio _dio;

  Stream<ChatStreamEvent> streamCompletion({
    required String baseUrl,
    required String? apiKey,
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
  }) async* {
    final endpoint = endpointResourceUri(baseUrl, 'chat/completions');
    final headers = endpointAuthorizationHeaders(
      endpoint: endpoint,
      apiKey: apiKey,
    );
    final response = await _dio.post<ResponseBody>(
      endpoint.toString(),
      data: {
        'model': model,
        'messages': messages.map((message) => message.toJson()).toList(),
        'stream': true,
        'stream_options': {'include_usage': true},
      },
      cancelToken: cancelToken,
      options: Options(
        headers: headers,
        followRedirects: endpointRequestMayFollowRedirects(headers),
        contentType: Headers.jsonContentType,
        responseType: ResponseType.stream,
      ),
    );
    final body = response.data;
    if (body == null) {
      throw const FormatException('Endpoint returned an empty stream');
    }
    final lines = body.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (cancelToken.isCancelled) return;
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      if (payload == '[DONE]') {
        yield const ChatStreamEvent(isTerminal: true);
        return;
      }
      final decoded = jsonDecode(payload);
      if (decoded is! Map) continue;
      final choices = decoded['choices'];
      String delta = '';
      String? finishReason;
      if (choices is List && choices.isNotEmpty && choices.first is Map) {
        final choice = choices.first as Map;
        final deltaMap = choice['delta'];
        if (deltaMap is Map && deltaMap['content'] is String) {
          delta = deltaMap['content'] as String;
        }
        finishReason = choice['finish_reason']?.toString();
      }
      final usage = decoded['usage'];
      yield ChatStreamEvent(
        delta: delta,
        finishReason: finishReason,
        usage: usage is Map ? ChatUsage.fromJson(usage) : null,
        isTerminal: finishReason != null,
      );
    }
  }

  Future<ChatCompletion> createCompletion({
    required String baseUrl,
    required String? apiKey,
    required String model,
    required List<ChatMessage> messages,
  }) async {
    if (model.trim().isEmpty) {
      throw const FormatException('A model is required');
    }
    if (messages.isEmpty) {
      throw const FormatException('At least one message is required');
    }

    final endpoint = endpointResourceUri(baseUrl, 'chat/completions');
    final headers = endpointAuthorizationHeaders(
      endpoint: endpoint,
      apiKey: apiKey,
    );
    final response = await _dio.post<Map<String, dynamic>>(
      endpoint.toString(),
      data: {
        'model': model,
        'messages': messages.map((message) => message.toJson()).toList(),
        'stream': false,
      },
      options: Options(
        headers: headers,
        followRedirects: endpointRequestMayFollowRedirects(headers),
        contentType: Headers.jsonContentType,
        responseType: ResponseType.json,
      ),
    );
    return parseCompletion(response.data);
  }

  static ChatCompletion parseCompletion(Map<String, dynamic>? data) {
    final choices = data?['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw const FormatException(
        'Endpoint returned an invalid chat completion',
      );
    }
    final choice = Map<String, dynamic>.from(choices.first as Map);
    final message = choice['message'];
    if (message is! Map || message['content'] is! String) {
      throw const FormatException('Completion does not contain text content');
    }
    return ChatCompletion(
      id: data?['id']?.toString(),
      content: message['content'] as String,
      finishReason: choice['finish_reason']?.toString(),
    );
  }
}
