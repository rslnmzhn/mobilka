import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/tool_execution.dart';
import 'package:mobilka/features/chat/presentation/chat_message_widgets.dart';
import 'package:mobilka/features/chat/presentation/tool_call_card.dart';

void main() {
  const call = ChatToolCall(
    id: 'call-1',
    name: 'read_memory',
    arguments: '{"file":"user.md"}',
  );

  Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('shows running state and expands input', (tester) async {
    await tester.pumpWidget(
      app(
        ToolCallCard(
          data: ToolCardData.fromExecution(
            const ToolExecution(
              assistantMessageId: 'assistant',
              callIndex: 0,
              callOccurrence: 0,
              call: call,
              status: ToolExecutionStatus.running,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const Key('tool-call-input-call-1')), findsNothing);
    await tester.tap(find.byKey(const Key('tool-call-toggle-call-1')));
    await tester.pump();
    expect(find.byKey(const Key('tool-call-input-call-1')), findsOneWidget);
    expect(find.textContaining('user.md'), findsOneWidget);
  });

  testWidgets('shows completed output and assistant text', (tester) async {
    final result = ChatMessage(
      id: 'result-1',
      role: ChatRole.tool,
      content: '{"ok":true,"value":"done"}',
      createdAt: DateTime(2026),
      toolCallId: call.id,
    );
    await tester.pumpWidget(
      app(
        MessageCard(
          message: ChatMessage(
            id: 'assistant-1',
            role: ChatRole.assistant,
            content: 'Working on it',
            createdAt: DateTime(2026),
            status: ChatMessageStatus.complete,
            toolCalls: const [call],
          ),
          toolExecutions: [
            ToolExecution(
              assistantMessageId: 'assistant-1',
              callIndex: 0,
              callOccurrence: 0,
              call: call,
              status: ToolExecutionStatus.completed,
              result: result,
            ),
          ],
        ),
      ),
    );

    expect(find.text('Working on it'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    await tester.tap(find.byKey(const Key('tool-call-toggle-call-1')));
    await tester.pump();
    expect(find.byKey(const Key('tool-call-output-call-1')), findsOneWidget);
    expect(find.textContaining('done'), findsOneWidget);
  });

  testWidgets('shows failed error', (tester) async {
    final result = ChatMessage(
      id: 'result-1',
      role: ChatRole.tool,
      content: '{"ok":false,"error":"boom"}',
      createdAt: DateTime(2026),
      toolCallId: call.id,
    );
    await tester.pumpWidget(
      app(
        ToolCallCard(
          data: ToolCardData.fromExecution(
            ToolExecution(
              assistantMessageId: 'assistant',
              callIndex: 0,
              callOccurrence: 0,
              call: call,
              status: ToolExecutionStatus.failed,
              result: result,
              error: 'boom',
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    await tester.tap(find.byKey(const Key('tool-call-toggle-call-1')));
    await tester.pump();
    expect(find.text('boom'), findsOneWidget);
  });

  testWidgets('result-less completed call is interrupted', (tester) async {
    await tester.pumpWidget(
      app(
        MessageCard(
          message: ChatMessage(
            id: 'assistant-interrupted',
            role: ChatRole.assistant,
            content: '',
            createdAt: DateTime(2026),
            toolCalls: const [call],
          ),
          toolExecutions: const [
            ToolExecution(
              assistantMessageId: 'assistant-interrupted',
              callIndex: 0,
              callOccurrence: 0,
              call: call,
              status: ToolExecutionStatus.failed,
              error: 'Execution was interrupted',
            ),
          ],
        ),
      ),
    );

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('duplicate call ids consume scoped results in order', (
    tester,
  ) async {
    final first = ChatMessage(
      id: 'result-1',
      role: ChatRole.tool,
      content: '{"ok":true,"value":1}',
      createdAt: DateTime(2026),
      toolCallId: call.id,
    );
    final second = ChatMessage(
      id: 'result-2',
      role: ChatRole.tool,
      content: '{"ok":false,"error":"second failed"}',
      createdAt: DateTime(2026),
      toolCallId: call.id,
    );
    await tester.pumpWidget(
      app(
        MessageCard(
          message: ChatMessage(
            id: 'assistant-duplicates',
            role: ChatRole.assistant,
            content: '',
            createdAt: DateTime(2026),
            toolCalls: const [call, call],
          ),
          toolExecutions: [
            ToolExecution(
              assistantMessageId: 'assistant-duplicates',
              callIndex: 0,
              callOccurrence: 0,
              call: call,
              status: ToolExecutionStatus.completed,
              result: first,
            ),
            ToolExecution(
              assistantMessageId: 'assistant-duplicates',
              callIndex: 1,
              callOccurrence: 1,
              call: call,
              status: ToolExecutionStatus.failed,
              result: second,
              error: 'second failed',
            ),
          ],
        ),
      ),
    );

    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('long payload does not overflow at 320 pixels', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final longCall = ChatToolCall(
      id: 'long',
      name: 'very_long_tool_name_that_must_fit_on_a_phone',
      arguments: '{"text":"${'x' * 4000}"}',
    );
    await tester.pumpWidget(
      app(
        ToolCallCard(
          data: ToolCardData.fromExecution(
            ToolExecution(
              assistantMessageId: 'assistant',
              callIndex: 0,
              callOccurrence: 0,
              call: longCall,
              status: ToolExecutionStatus.running,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('tool-call-toggle-long')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('header stays overflow-free with large text at 320 pixels', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(
      () => tester.platformDispatcher.clearTextScaleFactorTestValue(),
    );
    const longName = 'very_long_tool_name_that_must_fit_on_a_phone';
    await tester.pumpWidget(
      app(
        ToolCallCard(
          data: ToolCardData.fromExecution(
            ToolExecution(
              assistantMessageId: 'assistant',
              callIndex: 0,
              callOccurrence: 0,
              call: const ChatToolCall(
                id: 'big-text',
                name: longName,
                arguments: '{}',
              ),
              status: ToolExecutionStatus.completed,
              awaitingConfirmation: true,
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
