import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/data/chat_api_client.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';

void main() {
  test('serializes an OpenAI-compatible chat completion request', () async {
    final adapter = _RecordingAdapter(
      response: {
        'id': 'chat-1',
        'choices': [
          {
            'message': {'role': 'assistant', 'content': 'Hello'},
            'finish_reason': 'stop',
          },
        ],
      },
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final result = await ChatApiClient(dio).createCompletion(
      baseUrl: 'http://192.0.2.10:20129/v1',
      apiKey: 'test-key',
      model: 'test-model',
      messages: [
        ChatMessage(
          id: 'message-1',
          role: ChatRole.user,
          content: 'Hi',
          createdAt: DateTime(2026),
        ),
      ],
    );

    expect(
      adapter.uri.toString(),
      'http://192.0.2.10:20129/v1/chat/completions',
    );
    expect(adapter.headers?['Authorization'], 'Bearer test-key');
    expect(adapter.followRedirects, isFalse);
    expect(adapter.body, {
      'model': 'test-model',
      'messages': [
        {'role': 'user', 'content': 'Hi'},
      ],
      'stream': false,
    });
    expect(result.content, 'Hello');
    expect(result.finishReason, 'stop');
  });

  test('rejects malformed chat completion responses', () {
    expect(
      () => ChatApiClient.parseCompletion({'choices': <dynamic>[]}),
      throwsFormatException,
    );
  });

  test('parses fragmented SSE events and usage', () async {
    final adapter = _StreamingAdapter([
      'data: {"choices":[{"delta":{"content":"Hel"},"finish_reason":null}]}\n',
      '\n',
      'data: {"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}\n',
      'data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}\n',
      'data: [DONE]\n',
    ]);
    final dio = Dio()..httpClientAdapter = adapter;
    final events = await ChatApiClient(dio)
        .streamCompletion(
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'key',
          model: 'model',
          messages: [
            ChatMessage(
              id: 'm1',
              role: ChatRole.user,
              content: 'Hi',
              createdAt: DateTime(2026),
            ),
          ],
          cancelToken: CancelToken(),
        )
        .toList();
    expect(events.map((event) => event.delta).join(), 'Hello');
    expect(
      events.where((event) => event.usage != null).single.usage?.totalTokens,
      5,
    );
    expect(events.where((event) => event.isTerminal), isNotEmpty);
    expect(adapter.followRedirects, isFalse);
  });

  test('a stream without finish reason or DONE closes as non-terminal', () async {
    final adapter = _StreamingAdapter([
      'data: {"choices":[{"delta":{"content":"Partial"},"finish_reason":null}]}\n',
    ]);
    final dio = Dio()..httpClientAdapter = adapter;

    final events = await ChatApiClient(dio)
        .streamCompletion(
          baseUrl: 'https://api.example.com/v1',
          apiKey: null,
          model: 'model',
          messages: [
            ChatMessage(
              id: 'm1',
              role: ChatRole.user,
              content: 'Hi',
              createdAt: DateTime(2026),
            ),
          ],
          cancelToken: CancelToken(),
        )
        .toList();

    expect(events.single.delta, 'Partial');
    expect(events.single.isTerminal, isFalse);
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({required this.response});

  final Map<String, dynamic> response;
  Uri? uri;
  Map<String, dynamic>? headers;
  bool? followRedirects;
  Object? body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    uri = options.uri;
    headers = options.headers;
    followRedirects = options.followRedirects;
    body = options.data;
    return ResponseBody.fromString(
      jsonEncode(response),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _StreamingAdapter implements HttpClientAdapter {
  _StreamingAdapter(this.chunks);
  final List<String> chunks;
  bool? followRedirects;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    followRedirects = options.followRedirects;
    return ResponseBody(
      Stream.fromIterable(chunks.map(utf8.encode)),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
