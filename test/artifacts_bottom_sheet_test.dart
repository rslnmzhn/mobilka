import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/artifacts/presentation/artifacts_bottom_sheet.dart';
import 'package:mobilka/features/artifacts/application/artifacts_controller.dart';
import 'package:mobilka/features/artifacts/domain/artifact.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mobilka-artifact-sheet');
    Hive.init(p.join(tempDir.path, 'hive'));
    await Hive.openBox<dynamic>('artifacts');
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk('artifacts');
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  Widget app(Widget child) => ProviderScope(
    child: MaterialApp(home: Scaffold(body: child)),
  );

  testWidgets('shows four tabs and empty artifact states', (tester) async {
    await tester.pumpWidget(app(const ArtifactsBottomSheet()));

    expect(find.byType(Tab), findsNWidgets(4));
    expect(find.text('artifacts.noCode'), findsOneWidget);
    await tester.tap(find.text('artifacts.documents'));
    await tester.pumpAndSettle();
    expect(find.text('artifacts.noDocuments'), findsOneWidget);
    await tester.tap(find.text('artifacts.preview'));
    await tester.pumpAndSettle();
    expect(find.text('artifacts.noPreview'), findsOneWidget);
  });

  testWidgets(
    'null conversation fails closed with no global documents or create',
    (tester) async {
      final legacy = Artifact(
        id: 'legacy',
        title: 'Global legacy artifact',
        content: 'body',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            artifactsControllerProvider.overrideWith(
              () => _Artifacts([legacy]),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: ArtifactsBottomSheet()),
          ),
        ),
      );
      await tester.tap(find.text('artifacts.documents'));
      await tester.pumpAndSettle();
      expect(find.text('Global legacy artifact'), findsNothing);
      expect(find.byKey(const Key('artifact-create')), findsNothing);
    },
  );

  testWidgets('logs show completed failed and running calls', (tester) async {
    final conversation = _conversation([
      ChatMessage(
        id: 'assistant',
        role: ChatRole.assistant,
        content: '',
        createdAt: DateTime(2026),
        status: ChatMessageStatus.streaming,
        toolCalls: const [
          ChatToolCall(id: 'done', name: 'done_tool', arguments: '{}'),
          ChatToolCall(id: 'failed', name: 'failed_tool', arguments: '{}'),
          ChatToolCall(id: 'running', name: 'running_tool', arguments: '{}'),
        ],
      ),
      ChatMessage(
        id: 'done-result',
        role: ChatRole.tool,
        content: '{"ok":true}',
        createdAt: DateTime(2026),
        toolCallId: 'done',
      ),
      ChatMessage(
        id: 'failed-result',
        role: ChatRole.tool,
        content: '{"ok":false,"error":"boom"}',
        createdAt: DateTime(2026),
        toolCallId: 'failed',
      ),
    ]);
    await tester.pumpWidget(
      app(ArtifactsBottomSheet(conversation: conversation)),
    );
    await tester.drag(find.byType(TabBar), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('artifacts.logs'));
    await tester.pumpAndSettle();

    expect(find.text('done_tool'), findsOneWidget);
    expect(find.text('failed_tool'), findsOneWidget);
    expect(find.text('running_tool'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.pending_outlined), findsOneWidget);
  });

  testWidgets('fits at 320 pixels and expands a log', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final conversation = _conversation([
      ChatMessage(
        id: 'assistant',
        role: ChatRole.assistant,
        content: '',
        createdAt: DateTime(2026),
        toolCalls: const [
          ChatToolCall(
            id: 'call',
            name: 'long_tool_name_that_must_not_overflow',
            arguments: '{"value":"content"}',
          ),
        ],
      ),
      ChatMessage(
        id: 'result',
        role: ChatRole.tool,
        content: 'plain output',
        createdAt: DateTime(2026),
        toolCallId: 'call',
      ),
    ]);
    await tester.pumpWidget(
      app(ArtifactsBottomSheet(conversation: conversation)),
    );
    await tester.drag(find.byType(TabBar), const Offset(-800, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('artifacts.logs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('long_tool_name_that_must_not_overflow'));
    await tester.pumpAndSettle();

    expect(find.textContaining('plain output'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _Artifacts extends ArtifactsController {
  _Artifacts(this.items);
  final List<Artifact> items;
  @override
  List<Artifact> build() => items;
}

Conversation _conversation(List<ChatMessage> messages) => Conversation(
  id: 'conversation',
  title: 'Conversation',
  modelId: 'model',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  messages: messages,
);
