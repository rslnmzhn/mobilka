import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/presentation/chat_screen.dart';
import 'package:mobilka/features/models/application/models_controller.dart';
import 'package:mobilka/features/models/domain/ai_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpPicker(
    WidgetTester tester, {
    required ModelsState models,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet<String>(
                context: context,
                isScrollControlled: true,
                builder: (_) => ModelPickerSheet(models: models),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('model picker ranks favorites first and filters by search', (
    tester,
  ) async {
    await pumpPicker(
      tester,
      models: const ModelsState(
        models: [
          AiModel(id: 'zeta-model'),
          AiModel(id: 'alpha-model'),
        ],
        favorites: {'zeta-model'},
        hidden: {},
        selectedModelId: 'alpha-model',
      ),
    );

    expect(
      tester.getTopLeft(find.text('zeta-model')).dy,
      lessThan(tester.getTopLeft(find.text('alpha-model')).dy),
    );

    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pump();

    expect(find.text('alpha-model'), findsOneWidget);
    expect(find.text('zeta-model'), findsNothing);
  });
}
