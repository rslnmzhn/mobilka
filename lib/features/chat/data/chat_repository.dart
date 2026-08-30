import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../agents/application/agents_controller.dart';
import '../../settings/data/settings_repository.dart';
import '../../memory/application/context_injector.dart';
import '../../memory/application/memory_context_snapshot_service.dart';
import '../../models/domain/model_capabilities.dart';
import '../domain/chat_message.dart';
import '../domain/chat_stream_event.dart';
import '../domain/chat_tool.dart';
import '../application/automatic_title_parser.dart';
import 'chat_api_client.dart';

part 'chat_repository.g.dart';

@Riverpod(keepAlive: true)
ChatRepository chatRepository(Ref ref) => ChatRepository(
  ChatApiClient(
    Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(minutes: 2),
      ),
    ),
  ),
  ref.watch(settingsRepositoryProvider),
  ContextInjector.atomic(
    ref.watch(memoryContextSnapshotServiceProvider),
    ref.watch(selectedAgentPromptAdapterProvider),
  ),
);

abstract interface class ChatCompletionStreamer {
  Stream<ChatStreamEvent> streamCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
    List<ChatToolDefinition> tools = const [],
  });
}

abstract interface class SubagentCompletionStreamer {
  Stream<ChatStreamEvent> streamSubagentCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
  });
}

class ChatRepository
    implements ChatCompletionStreamer, SubagentCompletionStreamer {
  ChatRepository(
    this._apiClient,
    this._settingsRepository,
    this._contextInjector,
  );

  final ChatApiClient _apiClient;
  final SettingsRepository _settingsRepository;
  final ContextInjector _contextInjector;

  Future<ChatCompletion> createCompletion({
    required String model,
    required List<ChatMessage> messages,
  }) async {
    final settings = await _settingsRepository.load();
    final apiKey = await _settingsRepository.readApiKey();
    final injectedMessages = await _contextInjector.inject(messages);
    return _apiClient.createCompletion(
      baseUrl: settings.baseUrl,
      apiKey: apiKey,
      model: model,
      messages: injectedMessages,
    );
  }

  Future<String> createAutomaticTitle({
    required String model,
    required String firstUserText,
    required String assistantText,
  }) async {
    final settings = await _settingsRepository.load();
    final apiKey = await _settingsRepository.readApiKey();
    final token = CancelToken();
    final timer = Timer(
      const Duration(seconds: 10),
      () => token.cancel('title timeout'),
    );
    try {
      final completion = await _apiClient.createCompletion(
        baseUrl: settings.baseUrl,
        apiKey: apiKey,
        model: model,
        cancelToken: token,
        messages: [
          ChatMessage(
            id: 'title-system',
            role: ChatRole.system,
            content:
                'Return only one concise title in the conversation language. '
                'Maximum 6 words and 48 characters. No prefix, quotes, or Markdown.',
            createdAt: DateTime.now(),
          ),
          ChatMessage(
            id: 'title-user',
            role: ChatRole.user,
            content:
                'User: ${_clip(firstUserText)}\n'
                'Assistant: ${_clip(assistantText)}',
            createdAt: DateTime.now(),
          ),
        ],
      );
      final parsed = parseAutomaticConversationTitle(completion.content);
      if (parsed == null) throw const FormatException('Invalid title');
      return parsed;
    } finally {
      timer.cancel();
    }
  }

  static String _clip(String value) =>
      value.length <= 500 ? value : value.substring(0, 500);

  @override
  Stream<ChatStreamEvent> streamCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
    List<ChatToolDefinition> tools = const [],
  }) async* {
    final settings = await _settingsRepository.load();
    final apiKey = await _settingsRepository.readApiKey();
    final injectedMessages = await _contextInjector.inject(messages);
    // Capability gate (roadmap item 45): endpoints/models without function
    // calling must not receive a tools field at all.
    final capabilities = ModelCapabilityResolver.resolve(model);
    yield* _apiClient.streamCompletion(
      baseUrl: settings.baseUrl,
      apiKey: apiKey,
      model: model,
      messages: injectedMessages,
      cancelToken: cancelToken,
      tools: capabilities.tools
          ? tools.map((tool) => tool.toJson()).toList(growable: false)
          : const <Map<String, dynamic>>[],
    );
  }

  @override
  Stream<ChatStreamEvent> streamSubagentCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
  }) async* {
    final settings = await _settingsRepository.load();
    final apiKey = await _settingsRepository.readApiKey();
    yield* _apiClient.streamCompletion(
      baseUrl: settings.baseUrl,
      apiKey: apiKey,
      model: model,
      messages: messages,
      cancelToken: cancelToken,
    );
  }
}
