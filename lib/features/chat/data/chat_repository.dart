import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../agents/application/agents_controller.dart';
import '../../settings/data/settings_repository.dart';
import '../../memory/application/context_injector.dart';
import '../../memory/application/memory_mutation_coordinator.dart';
import '../../memory/application/persona_registry.dart';
import '../../memory/data/context_sources.dart';
import '../../memory/data/memory_repository.dart';
import '../../models/domain/model_capabilities.dart';
import '../domain/chat_message.dart';
import '../domain/chat_stream_event.dart';
import '../domain/chat_tool.dart';
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
      ref.watch(memoryRepositoryProvider),
      // Read per request: the coordinator is invalidated when the memory
      // folder changes, and this keepAlive repository must not pin a stale
      // null captured before configuration.
      () => ref.read(memoryMutationCoordinatorProvider),
    ),
    ref.watch(selectedAgentPromptAdapterProvider),
    () async => ref.read(personaRegistryProvider).overlayText(),
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
