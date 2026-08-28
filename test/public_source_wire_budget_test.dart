import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/automatic_title_coordinator.dart';
import 'package:mobilka/features/chat/application/chat_stream_request.dart';
import 'package:mobilka/features/chat/application/chat_tool_executor.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/public_source/application/public_source_policy.dart';
import 'package:mobilka/features/public_source/application/public_source_reader.dart';

void main() {
  test(
    'concurrent accounting is serialized at exact 8 MiB without overshoot',
    () async {
      var conversation = _conversation();
      final coordinator = AutomaticTitleCoordinator(
        conversationById: (_) => conversation,
        persist: (value) async => conversation = value,
      );
      final executor = ChatToolExecutor(
        runtime: _NoopRuntime(),
        conversationById: (_) => conversation,
        persistMutation: coordinator.mutate,
      );
      final context = executor.publicSourceContextForTest(_request());
      await Future.wait([
        context.consumePublicSourceWireBytes!(4 * 1024 * 1024),
        context.consumePublicSourceWireBytes!(4 * 1024 * 1024),
      ]);
      expect(
        conversation.publicSourceWireBytesUsed,
        publicSourceConversationWireLimit,
      );
      await expectLater(
        context.consumePublicSourceWireBytes!(1),
        throwsA(isA<PublicSourceFailure>()),
      );
      expect(
        conversation.publicSourceWireBytesUsed,
        publicSourceConversationWireLimit,
      );
    },
  );

  test(
    'deletion and a new conversation reset persisted accounting explicitly',
    () {
      final old = _conversation().copyWith(publicSourceWireBytesUsed: 1234);
      final restored = Conversation.fromJson(old.toJson());
      expect(restored.publicSourceWireBytesUsed, 1234);
      final conversations = <String, Conversation>{old.id: restored}
        ..remove(old.id);
      conversations['new'] = _conversation(id: 'new');
      expect(conversations['new']!.publicSourceWireBytesUsed, 0);
    },
  );
}

Conversation _conversation({String id = 'c'}) => Conversation(
  id: id,
  title: 't',
  modelId: 'm',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  pendingRequestMessageId: 'r',
  messages: const [],
);

ChatStreamRequest _request() => ChatStreamRequest(
  conversationId: 'c',
  sessionKey: 's',
  requestMessageId: 'r',
  assistantMessageId: 'a',
  modelId: 'm',
  history: const [],
  selectedAgentId: null,
  allowedTools: const {},
);

class _NoopRuntime implements ChatToolRuntime {
  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async => const [];
  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) async => '{}';
}
