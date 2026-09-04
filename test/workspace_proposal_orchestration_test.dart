import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/chat_tool_executor.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart';
import 'package:mobilka/features/chat/application/chat_streaming_coordinator.dart';
import 'package:mobilka/features/chat/application/request_tool_security_state.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/chat/domain/pending_memory_proposal.dart';
import 'package:mobilka/features/chat/domain/request_execution_ledger.dart';
import 'package:mobilka/features/memory/application/workspace_paths.dart';
import 'package:mobilka/features/chat/domain/pending_workspace_proposal.dart';
import 'package:mobilka/features/workspace/domain/workspace_models.dart';

import 'support/chat_streaming_coordinator_fakes.dart' show EventStreamer;

void main() {
  test(
    'executor persists one workspace proposal and rejects later calls',
    () async {
      var conversation = _conversation();
      final runtime = _Runtime();
      final executor = ChatToolExecutor(
        runtime: runtime,
        conversationById: (_) => conversation,
        persistMutation: (_, mutation) async {
          final updated = mutation(conversation);
          if (updated != null) conversation = updated;
          return updated;
        },
      );

      final shouldContinue = await executor.execute(
        _request(),
        'assistant',
        const [
          ChatToolCall(
            id: 'first',
            name: 'write_file',
            arguments: '{"path":"a.txt","content":"one"}',
          ),
          ChatToolCall(
            id: 'second',
            name: 'delete_file',
            arguments: '{"path":"b.txt"}',
          ),
        ],
        securityState: RequestToolSecurityState(
          conversationId: 'conversation',
          requestId: 'request',
          readLedger: () => conversation.requestExecutionLedger!,
          appendLedgerEntry: (entry) async {
            final ledger = conversation.requestExecutionLedger!.append(entry);
            conversation = conversation.copyWith(
              requestExecutionLedger: ledger,
            );
            return ledger;
          },
        ),
      );

      expect(shouldContinue, isFalse);
      expect(conversation.pendingWorkspaceProposal?.toolCallId, 'first');
      expect(conversation.pendingWorkspaceProposal?.toolCallIndex, 0);
      expect(conversation.pendingWorkspaceProposal?.proposedContent, 'one');
      expect(runtime.executed, isEmpty);
      final rejected = conversation.messages.singleWhere(
        (message) => message.toolCallId == 'second',
      );
      expect(rejected.content, contains('confirmation_pending'));
    },
  );

  test('workspace proposal blocks later memory and generic calls', () async {
    var conversation = _conversation();
    final runtime = _Runtime();
    final executor = ChatToolExecutor(
      runtime: runtime,
      conversationById: (_) => conversation,
      persistMutation: (_, mutation) async {
        final updated = mutation(conversation);
        if (updated != null) conversation = updated;
        return updated;
      },
    );

    await executor.execute(
      _request(
        allowedTools: const {'write_file', 'update_memory_file', 'ping'},
      ),
      'assistant',
      const [
        ChatToolCall(id: 'workspace', name: 'write_file', arguments: '{}'),
        ChatToolCall(id: 'memory', name: 'update_memory_file', arguments: '{}'),
        ChatToolCall(id: 'generic', name: 'ping', arguments: '{}'),
      ],
      securityState: _security(
        () => conversation,
        (value) => conversation = value,
      ),
    );

    expect(conversation.pendingWorkspaceProposal, isNotNull);
    expect(runtime.executed, isEmpty);
    expect(
      conversation.messages.where((message) => message.role == ChatRole.tool),
      hasLength(2),
    );
  });

  test('memory proposal blocks later workspace call', () async {
    var conversation = _conversation();
    final runtime = _Runtime();
    final executor = ChatToolExecutor(
      runtime: runtime,
      conversationById: (_) => conversation,
      persistMutation: (_, mutation) async {
        final updated = mutation(conversation);
        if (updated != null) conversation = updated;
        return updated;
      },
    );

    await executor.execute(
      _request(allowedTools: const {'update_memory_file', 'write_file'}),
      'assistant',
      const [
        ChatToolCall(
          id: 'memory',
          name: 'update_memory_file',
          arguments: '{"file_name":"user.md","content":"new"}',
        ),
        ChatToolCall(id: 'workspace', name: 'write_file', arguments: '{}'),
      ],
      securityState: _security(
        () => conversation,
        (value) => conversation = value,
      ),
    );

    expect(conversation.pendingMemoryProposal, isNotNull);
    expect(conversation.pendingWorkspaceProposal, isNull);
  });

  test('conversation JSON round-trips the exact workspace proposal', () {
    final proposal = _proposal();
    final conversation = _conversation().copyWith(
      pendingWorkspaceProposal: proposal,
      messages: [
        ChatMessage(
          id: 'assistant',
          role: ChatRole.assistant,
          content: '',
          createdAt: DateTime.utc(2026),
          status: ChatMessageStatus.streaming,
          toolCalls: const [
            ChatToolCall(id: 'first', name: 'write_file', arguments: '{}'),
          ],
        ),
      ],
    );
    final decoded = Conversation.fromJson(conversation.toJson());

    expect(decoded.pendingWorkspaceProposal?.toJson(), proposal.toJson());
  });

  test('proposal decode failures preserve and terminalize conversation', () {
    final base = _conversation()
        .copyWith(pendingWorkspaceProposal: _proposal())
        .toJson();
    final mutations = <void Function(Map<dynamic, dynamic>)>[
      (proposal) => proposal['status'] = 'future',
      (proposal) => proposal[1] = 'non-string-key',
      (proposal) => proposal['workspaceBindingSnapshot'] = {'value': 1},
      (proposal) => proposal['callOccurrence'] = 'zero',
      (proposal) => proposal['selectedAgentId'] = 7,
    ];

    for (final mutate in mutations) {
      final json = Map<dynamic, dynamic>.from(base);
      final proposal = Map<dynamic, dynamic>.from(
        json['pendingWorkspaceProposal'] as Map,
      );
      mutate(proposal);
      json['pendingWorkspaceProposal'] = proposal;
      final decoded = Conversation.fromJson(json);
      expect(decoded.id, base['id']);
      expect(decoded.pendingWorkspaceProposal, isNull);
      expect(decoded.invalidPendingWorkspaceProposal, isTrue);
    }
  });

  test(
    'workspace result follows preceding read in assistant call order',
    () async {
      var conversation = _conversation();
      final runtime = _Runtime();
      final executor = ChatToolExecutor(
        runtime: runtime,
        conversationById: (_) => conversation,
        persistMutation: (_, mutation) async {
          final updated = mutation(conversation);
          if (updated != null) conversation = updated;
          return updated;
        },
      );
      const calls = [
        ChatToolCall(id: 'read', name: 'ping', arguments: '{}'),
        ChatToolCall(id: 'write', name: 'write_file', arguments: '{}'),
      ];
      await executor.execute(
        _request(allowedTools: const {'ping', 'write_file'}),
        'assistant',
        calls,
        securityState: _security(
          () => conversation,
          (value) => conversation = value,
        ),
      );
      final proposal = conversation.pendingWorkspaceProposal!;
      expect(proposal.toolCallIndex, 1);

      final coordinator = ChatStreamingCoordinator(
        streamer: EventStreamer(const []),
        conversationById: (_) => conversation,
        publishError: (_) {},
        persistMutation: (_, mutation) async {
          final updated = mutation(conversation);
          if (updated != null) conversation = updated;
          return updated;
        },
      );
      await coordinator.continueAfterWorkspaceDecision(
        conversation: conversation,
        proposal: proposal,
        toolResult: '{"ok":true}',
        workspaceBinding: null,
        continueStreaming: false,
      );
      expect(
        conversation.messages
            .where((message) => message.role == ChatRole.tool)
            .map((message) => message.toolCallIndex),
        [0, 1],
      );
    },
  );

  test('duplicate IDs retain absolute result ordinals', () async {
    var conversation = _conversation();
    final executor = ChatToolExecutor(
      runtime: _Runtime(),
      conversationById: (_) => conversation,
      persistMutation: (_, mutation) async {
        final updated = mutation(conversation);
        if (updated != null) conversation = updated;
        return updated;
      },
    );
    await executor.execute(
      _request(allowedTools: const {'ping', 'write_file'}),
      'assistant',
      const [
        ChatToolCall(id: 'same', name: 'ping', arguments: '{}'),
        ChatToolCall(id: 'same', name: 'write_file', arguments: '{}'),
      ],
      securityState: _security(
        () => conversation,
        (value) => conversation = value,
      ),
    );
    expect(conversation.pendingWorkspaceProposal!.callOccurrence, 1);
    expect(conversation.pendingWorkspaceProposal!.toolCallIndex, 1);
    expect(
      conversation.messages
          .singleWhere((message) => message.role == ChatRole.tool)
          .toolCallIndex,
      0,
    );
  });
}

final class _Runtime
    implements
        ChatToolRuntime,
        WorkspaceProposalRuntime,
        MemoryProposalRuntime {
  final executed = <String>[];

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async => const [
    ChatToolDefinition(
      name: 'write_file',
      effect: ChatToolEffect.runtimeConfirmed,
      description: 'write',
      parameters: {'type': 'object'},
    ),
    ChatToolDefinition(
      name: 'ping',
      effect: ChatToolEffect.readOnly,
      description: 'ping',
      parameters: {'type': 'object'},
    ),
    ChatToolDefinition(
      name: 'delete_file',
      effect: ChatToolEffect.runtimeConfirmed,
      description: 'delete',
      parameters: {'type': 'object'},
    ),
  ];

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) async {
    executed.add(call.name);
    return '{"ok":true}';
  }

  @override
  bool handlesWorkspaceMutation(String toolName) =>
      toolName == 'write_file' || toolName == 'delete_file';

  @override
  Future<PendingWorkspaceProposal> prepareWorkspaceProposal({
    required ChatToolCall call,
    required ChatToolExecutionContext context,
    required String requestId,
    required String assistantMessageId,
    required String? selectedAgentId,
    required Set<String> allowedTools,
    required int callOccurrence,
    required int toolCallIndex,
  }) async => _proposal(
    toolCallIndex: toolCallIndex,
    toolCallId: call.id,
    callOccurrence: callOccurrence,
  );

  @override
  Future<void> revalidateWorkspacePermission({
    required PendingWorkspaceProposal proposal,
    required String? selectedAgentId,
    required Set<String> allowedTools,
  }) async {}

  @override
  Future<PendingMemoryProposal?> prepareMemoryProposal(
    ChatToolCall call,
    String assistantId,
    String? selectedAgentId,
    Set<String> allowedTools, [
    int occurrence = 0,
  ]) async => PendingMemoryProposal(
    assistantMessageId: assistantId,
    toolCallId: call.id,
    callOccurrence: occurrence,
    fileName: 'user.md',
    proposedContent: 'new',
    diff: '+new',
    confirmationToken: 'token',
    version: 'version',
    createdAt: DateTime.utc(2026),
    selectedAgentId: selectedAgentId!,
    allowedTools: allowedTools,
  );

  @override
  Future<void> revalidateMemoryToolPermission({
    required String toolName,
    required String? selectedAgentId,
    required Set<String> allowedTools,
  }) async {}

  @override
  Future<void> revalidateMemoryProposal(PendingMemoryProposal proposal) async {}
}

Conversation _conversation() => Conversation(
  id: 'conversation',
  title: 'title',
  modelId: 'model',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  pendingRequestMessageId: 'request',
  sessionKey: 'session',
  requestExecutionLedger: const RequestExecutionLedger(
    requestId: 'request',
    entries: [],
  ),
  messages: [
    ChatMessage(
      id: 'assistant',
      role: ChatRole.assistant,
      content: '',
      createdAt: DateTime.utc(2026),
      status: ChatMessageStatus.streaming,
    ),
  ],
);

ChatStreamRequest _request({
  Set<String> allowedTools = const {'write_file', 'delete_file'},
}) => ChatStreamRequest(
  conversationId: 'conversation',
  sessionKey: 'session',
  requestMessageId: 'request',
  assistantMessageId: 'assistant',
  modelId: 'model',
  history: const [],
  selectedAgentId: 'agent',
  allowedTools: allowedTools,
  workspaceBinding: const WorkspaceBinding.fakeForTest(),
);

RequestToolSecurityState _security(
  Conversation Function() read,
  void Function(Conversation value) write,
) => RequestToolSecurityState(
  conversationId: 'conversation',
  requestId: 'request',
  readLedger: () => read().requestExecutionLedger!,
  appendLedgerEntry: (entry) async {
    final ledger = read().requestExecutionLedger!.append(entry);
    write(read().copyWith(requestExecutionLedger: ledger));
    return ledger;
  },
);

PendingWorkspaceProposal _proposal({
  int toolCallIndex = 0,
  String toolCallId = 'first',
  int callOccurrence = 0,
}) {
  final now = DateTime.utc(2026);
  const content = 'one';
  const preview = 'CREATE a.txt\none';
  return PendingWorkspaceProposal(
    conversationId: 'conversation',
    requestId: 'request',
    assistantMessageId: 'assistant',
    toolCallId: toolCallId,
    callOccurrence: callOccurrence,
    toolCallIndex: toolCallIndex,
    operation: 'write_file',
    path: 'a.txt',
    proposedContent: content,
    proposedContentHash: workspaceHash(utf8.encode(content)),
    preview: preview,
    previewHash: workspaceHash(utf8.encode(preview)),
    targetMissing: true,
    sessionKey: 'session',
    allowedTools: const {'write_file', 'delete_file'},
    selectedAgentId: 'agent',
    workspaceBindingSnapshot: const WorkspaceBindingSnapshot(
      isContentUri: false,
      value: 'test-root',
      identity: 'false:test-root',
      rootIdentity: 'false:test-root',
    ),
    createdAt: now,
    expiresAt: now.add(const Duration(minutes: 15)),
  );
}
