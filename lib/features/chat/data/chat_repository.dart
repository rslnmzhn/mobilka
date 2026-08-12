import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:saf/saf.dart';

import '../../settings/data/settings_repository.dart';
import '../../agents/application/agents_controller.dart';
import '../../memory/application/context_injector.dart';
import '../../memory/data/context_sources.dart';
import '../../memory/data/memory_selection_store.dart';
import '../domain/chat_message.dart';
import '../domain/chat_stream_event.dart';
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
  ContextInjector(
    StoredMemoryContextSource(
      MemorySelectionStore(),
      SafMemoryReaderAdapter(Saf()),
    ),
    ref.watch(selectedAgentPromptAdapterProvider),
  ),
);

abstract interface class ChatCompletionStreamer {
  Stream<ChatStreamEvent> streamCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
  });
}

class ChatRepository implements ChatCompletionStreamer {
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

  @override
  Stream<ChatStreamEvent> streamCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
  }) async* {
    final settings = await _settingsRepository.load();
    final apiKey = await _settingsRepository.readApiKey();
    final injectedMessages = await _contextInjector.inject(messages);
    yield* _apiClient.streamCompletion(
      baseUrl: settings.baseUrl,
      apiKey: apiKey,
      model: model,
      messages: injectedMessages,
      cancelToken: cancelToken,
    );
  }
}
