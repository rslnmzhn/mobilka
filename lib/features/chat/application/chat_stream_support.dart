import 'package:dio/dio.dart';

import '../domain/chat_stream_event.dart';
import '../domain/chat_message.dart';

class ToolCallBuffer {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();

  void append(ChatToolCallDelta delta) {
    if (delta.id.isNotEmpty) id = delta.id;
    if (delta.name.isNotEmpty) name = delta.name;
    arguments.write(delta.arguments);
  }

  ChatToolCall build() {
    if (id.isEmpty || name.isEmpty) {
      throw const FormatException('Incomplete tool call');
    }
    return ChatToolCall(id: id, name: name, arguments: arguments.toString());
  }
}

bool isTransientChatError(DioException error) => switch (error.type) {
  DioExceptionType.connectionTimeout ||
  DioExceptionType.sendTimeout ||
  DioExceptionType.receiveTimeout ||
  DioExceptionType.connectionError => true,
  _ => false,
};

String friendlyChatError(DioException error) => switch (error.type) {
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
