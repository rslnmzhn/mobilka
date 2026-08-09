import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/models/application/models_controller.dart';
import 'package:mobilka/features/models/domain/ai_model.dart';

void main() {
  test('visibleModels excludes hidden models', () {
    const state = ModelsState(
      models: [
        AiModel(id: 'alpha'),
        AiModel(id: 'beta'),
      ],
      favorites: {'alpha'},
      hidden: {'beta'},
      selectedModelId: 'alpha',
    );

    expect(state.visibleModels.map((model) => model.id), ['alpha']);
  });
}
