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
    List<Map<String, dynamic>> tools = const [],
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
        if (tools.isNotEmpty) 'tools': tools,
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
      String reasoningDelta = '';
      String? finishReason;
      var toolCallDeltas = const <ChatToolCallDelta>[];
      if (choices is List && choices.isNotEmpty && choices.first is Map) {
        final choice = choices.first as Map;
        final deltaMap = choice['delta'];
        if (deltaMap is Map) {
          final content = deltaMap['content'];
          if (content is String) {
            delta = content;
          } else if (content is List) {
            // Multi-part content: concatenate text parts, ignore images.
            for (final part in content) {
              if (part is Map &&
                  part['type'] == 'text' &&
                  part['text'] is String) {
                delta += part['text'] as String;
              }
            }
          }
          // Reasoning streams: OpenRouter uses `reasoning`, DeepSeek-style
          // endpoints use `reasoning_content`.
          for (final key in const ['reasoning', 'reasoning_content']) {
            final value = deltaMap[key];
            if (value is String && value.isNotEmpty) {
              reasoningDelta += value;
            }
          }
          toolCallDeltas = _parseToolCallDeltas(deltaMap['tool_calls']);
        }
        finishReason = choice['finish_reason']?.toString();
        // Non-stream reasoning payloads put the whole block on the message.
        final message = choice['message'];
        if (message is Map) {
          for (final key in const ['reasoning', 'reasoning_content']) {
            final value = message[key];
            if (value is String && value.isNotEmpty) {
              reasoningDelta += value;
            }
          }
        }
      }
      final usage = decoded['usage'];
      yield ChatStreamEvent(
        delta: delta,
        reasoningDelta: reasoningDelta,
        finishReason: finishReason,
        usage: usage is Map ? ChatUsage.fromJson(usage) : null,
        toolCallDeltas: toolCallDeltas,
      );
    }
  }

  static List<ChatToolCallDelta> _parseToolCallDeltas(dynamic value) {
    if (value == null) return const [];
    if (value is! List) {
      throw const FormatException('Invalid tool_calls delta');
    }
    return value
        .map((item) {
          if (item is! Map || item['index'] is! int) {
            throw const FormatException('Invalid tool call delta');
          }
          final function = item['function'];
          if (function != null && function is! Map) {
            throw const FormatException('Invalid tool call function delta');
          }
          return ChatToolCallDelta(
            index: item['index'] as int,
            id: item['id']?.toString() ?? '',
            name: function is Map ? function['name']?.toString() ?? '' : '',
            arguments: function is Map
                ? function['arguments']?.toString() ?? ''
                : '',
          );
        })
        .toList(growable: false);
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
