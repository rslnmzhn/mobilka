import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/presentation/chat_header.dart';
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

  testWidgets(
    'header shows current identity and exposes only new chat control',
    (tester) async {
      var modelTaps = 0;
      var newChatTaps = 0;
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: ChatHeaderBar(
              title: 'A very long authoritative conversation title for mobile',
              modelId: 'provider/very-long-current-conversation-model-id',
              onModelPressed: () => modelTaps++,
              onNewChat: () => newChatTaps++,
            ),
          ),
        ),
      );

      expect(find.textContaining('authoritative conversation'), findsOneWidget);
      expect(find.textContaining('provider/very-long'), findsOneWidget);
      expect(find.byKey(const Key('new-chat')), findsOneWidget);
      expect(find.byIcon(Icons.menu), findsNothing);
      expect(find.byIcon(Icons.tune), findsOneWidget);
      expect(find.byIcon(Icons.inventory_2_outlined), findsNothing);
      final context = tester.element(
        find.byKey(const Key('chat-header-model')),
      );
      final text = tester.widget<Text>(
        find.textContaining('provider/very-long'),
      );
      final icon = tester.widget<Icon>(
        find.byKey(const Key('chat-header-model-icon')),
      );
      expect(text.style?.color, Theme.of(context).colorScheme.primary);
      expect(icon.color, Theme.of(context).colorScheme.primary);
      expect(find.byType(Tooltip), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('chat-header-model')));
      await tester.tap(find.byKey(const Key('chat-header-model-icon')));
      await tester.tap(find.byKey(const Key('new-chat')));
      expect(modelTaps, 2);
      expect(newChatTaps, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
