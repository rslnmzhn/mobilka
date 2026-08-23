import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/chat/application/chat_controller.dart';
import 'package:mobilka/features/chat/data/conversation_store.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/models/application/models_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chat-model-switch-');
    Hive.init(root.path);
    await Hive.openBox<dynamic>('conversations');
  });

  tearDown(() async {
    await Hive.close();
    await root.delete(recursive: true);
  });

  Future<ProviderContainer> bootstrap({
    required List<Conversation> conversations,
    required _FakeModelsController models,
  }) async {
    for (final conversation in conversations) {
      await ConversationStore().save(conversation);
    }
    final providerContainer = ProviderContainer(
      overrides: [modelsControllerProvider.overrideWith(() => models)],
    );
    addTearDown(providerContainer.dispose);
    await providerContainer.read(chatControllerProvider.future);
    return providerContainer;
  }

  test('applyModel switches the active conversation and persists it', () async {
    final conversation = Conversation(
      id: 'conversation',
      title: 'Chat',
      modelId: 'model-a',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      messages: const [],
    );
    final models = _FakeModelsController(initialSelectedModelId: 'model-a');
    final providerContainer = await bootstrap(
      conversations: [conversation],
      models: models,
    );

    await providerContainer
        .read(chatControllerProvider.notifier)
        .applyModel('model-b');

    final state = providerContainer.read(chatControllerProvider).requireValue;
    expect(state.activeConversation!.modelId, 'model-b');
    expect(models.selectedModelId, 'model-b');
    final stored = ConversationStore().loadAll().firstWhere(
      (item) => item.id == 'conversation',
    );
    expect(stored.modelId, 'model-b');
  });

  test(
    'applyModel without a conversation only updates the global choice',
    () async {
      final models = _FakeModelsController(initialSelectedModelId: 'model-a');
      final providerContainer = await bootstrap(
        conversations: const [],
        models: models,
      );

      await providerContainer
          .read(chatControllerProvider.notifier)
          .applyModel('model-b');

      expect(
        providerContainer
            .read(chatControllerProvider)
            .requireValue
            .conversations,
        isEmpty,
      );
      expect(models.selectedModelId, 'model-b');
    },
  );
}

class _FakeModelsController extends ModelsController {
  _FakeModelsController({required this.initialSelectedModelId});

  final String initialSelectedModelId;
  String? selectedModelId;

  @override
  Future<ModelsState> build() async => ModelsState(
    models: const [],
    favorites: const {},
    hidden: const {},
    selectedModelId: selectedModelId ?? initialSelectedModelId,
  );

  @override
  Future<void> select(String id) async {
    selectedModelId = id;
    state = AsyncData(
      ModelsState(
        models: const [],
        favorites: const {},
        hidden: const {},
        selectedModelId: id,
      ),
    );
  }
}
