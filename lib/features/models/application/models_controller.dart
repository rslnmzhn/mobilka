import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/storage/app_boxes.dart';
import '../data/models_repository.dart';
import '../domain/ai_model.dart';

part 'models_controller.g.dart';

class ModelsState {
  const ModelsState({
    required this.models,
    required this.favorites,
    required this.hidden,
    required this.selectedModelId,
  });
  final List<AiModel> models;
  final Set<String> favorites;
  final Set<String> hidden;
  final String? selectedModelId;

  List<AiModel> get visibleModels =>
      models.where((model) => !hidden.contains(model.id)).toList();
}

@Riverpod(keepAlive: true)
class ModelsController extends _$ModelsController {
  @override
  Future<ModelsState> build() async {
    final repository = ref.watch(modelsRepositoryProvider);
    return ModelsState(
      models: repository.cached(),
      favorites: repository.favorites(),
      hidden: repository.hidden(),
      selectedModelId: preferencesBox.get('selectedModel') as String?,
    );
  }

  Future<void> refresh() async {
    final current = state.value ?? await future;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final models = await ref.read(modelsRepositoryProvider).discover();
      return ModelsState(
        models: models,
        favorites: current.favorites,
        hidden: current.hidden,
        selectedModelId: current.selectedModelId,
      );
    });
  }

  Future<void> toggleFavorite(String id) async {
    final current = state.requireValue;
    final values = {...current.favorites};
    values.contains(id) ? values.remove(id) : values.add(id);
    await ref.read(modelsRepositoryProvider).setFavorites(values);
    state = AsyncData(
      ModelsState(
        models: current.models,
        favorites: values,
        hidden: current.hidden,
        selectedModelId: current.selectedModelId,
      ),
    );
  }

  Future<void> toggleHidden(String id) async {
    final current = state.requireValue;
    final values = {...current.hidden};
    values.contains(id) ? values.remove(id) : values.add(id);
    await ref.read(modelsRepositoryProvider).setHidden(values);
    state = AsyncData(
      ModelsState(
        models: current.models,
        favorites: current.favorites,
        hidden: values,
        selectedModelId: current.selectedModelId,
      ),
    );
  }

  Future<void> select(String id) async {
    final current = state.requireValue;
    await preferencesBox.put('selectedModel', id);
    state = AsyncData(
      ModelsState(
        models: current.models,
        favorites: current.favorites,
        hidden: current.hidden,
        selectedModelId: id,
      ),
    );
  }
}
