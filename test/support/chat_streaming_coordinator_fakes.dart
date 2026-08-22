import 'dart:async';

import 'package:dio/dio.dart';
import 'package:mobilka/features/chat/application/chat_streaming_coordinator.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart'
    as runtime;
import 'package:mobilka/features/chat/data/chat_repository.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_stream_event.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/chat/domain/pending_memory_proposal.dart';

class CoordinatorFixture {
  CoordinatorFixture({
    List<ChatStreamEvent>? events,
    ChatCompletionStreamer? streamer,
    runtime.ChatToolRuntime? toolRuntime,
  }) {
    conversations['conversation-1'] = conversationWithId(
      'conversation-1',
      pending: true,
    );
    coordinator = ChatStreamingCoordinator(
      streamer: streamer ?? EventStreamer(events ?? const []),
      conversationById: (id) => conversations[id],
      persistAndPublish: (conversation) async {
        persisted.add(conversation);
        conversations[conversation.id] = conversation;
      },
      publishError: errors.add,
      toolRuntime: toolRuntime,
    );
  }

  final Map<String, Conversation> conversations = {};
  final List<Conversation> persisted = [];
  final List<String> errors = [];
  late final ChatStreamingCoordinator coordinator;
  Conversation get conversation => conversations['conversation-1']!;
  ChatMessage get assistant => conversation.messages.last;

  Future<void> run() => coordinator.run(
    ChatStreamRequest(
      conversationId: 'conversation-1',
      requestMessageId: 'user-1',
      assistantMessageId: 'assistant-1',
      modelId: 'model',
      history: [conversation.messages.first],
      selectedAgentId: 'agent-1',
      allowedTools: const {'update_memory_file'},
    ),
  );
}

class EventStreamer implements ChatCompletionStreamer {
  const EventStreamer(this.events);
  final List<ChatStreamEvent> events;

  @override
  Stream<ChatStreamEvent> streamCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
    List<ChatToolDefinition> tools = const [],
  }) => Stream.fromIterable(events);
}

class ControlledStreamer implements ChatCompletionStreamer {
  final started = Completer<void>();

  @override
  Stream<ChatStreamEvent> streamCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
    List<ChatToolDefinition> tools = const [],
  }) async* {
    started.complete();
    await cancelToken.whenCancel;
  }
}

class SequencedStreamer implements ChatCompletionStreamer {
  SequencedStreamer(this.responses);
  final List<List<ChatStreamEvent>> responses;
  final List<List<ChatMessage>> histories = [];
  void Function()? onStart;

  @override
  Stream<ChatStreamEvent> streamCompletion({
    required String model,
    required List<ChatMessage> messages,
    required CancelToken cancelToken,
    List<ChatToolDefinition> tools = const [],
  }) {
    onStart?.call();
    histories.add(messages);
    return Stream.fromIterable(responses[histories.length - 1]);
  }
}

class ToolRuntime implements runtime.ChatToolRuntime {
  final List<ChatToolCall> calls = [];

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async => const [
    ChatToolDefinition(
      name: 'update_memory_file',
      description: 'update',
      parameters: {'type': 'object'},
    ),
  ];

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools,
  ) async {
    calls.add(call);
    return '{"ok":true}';
  }
}

class RejectingToolRuntime extends ToolRuntime {
  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools,
  ) async {
    calls.add(call);
    throw StateError('Unknown tool: ${call.name}');
  }
}

class MemoryProposalRuntime
    implements runtime.ChatToolRuntime, runtime.MemoryProposalRuntime {
  var executed = false;

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async => const [];

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools,
  ) async {
    executed = true;
    return '{}';
  }

  @override
  Future<PendingMemoryProposal?> prepareMemoryProposal(
    ChatToolCall call,
    String assistantMessageId,
    String? selectedAgentId,
    Set<String> allowedTools,
  ) async => PendingMemoryProposal(
    toolCallId: call.id,
    assistantMessageId: assistantMessageId,
    selectedAgentId: selectedAgentId ?? 'agent-1',
    allowedTools: allowedTools,
    fileName: 'user_profile.md',
    proposedContent: '# User\nnew\n',
    diff: '+new',
    confirmationToken: 'token',
    version: 'version',
    createdAt: DateTime.utc(2026),
  );

  @override
  Future<void> revalidateMemoryProposal(PendingMemoryProposal proposal) async {}
}

Conversation conversationWithId(String id, {bool pending = false}) {
  final now = DateTime.utc(2026);
  return Conversation(
    id: id,
    title: id,
    modelId: 'model',
    createdAt: now,
    updatedAt: now,
    pendingRequestMessageId: pending ? 'user-1' : null,
    messages: pending
        ? [
            ChatMessage(
              id: 'user-1',
              role: ChatRole.user,
              content: 'Question',
              createdAt: now,
            ),
            ChatMessage(
              id: 'assistant-1',
              role: ChatRole.assistant,
              content: '',
              createdAt: now,
              status: ChatMessageStatus.pending,
            ),
          ]
        : const [],
  );
}
