import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/core/storage/app_boxes.dart';
import 'package:mobilka/features/chat/application/chat_state.dart';
import 'package:mobilka/features/chat/data/conversation_store.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/chat/domain/pending_tool_proposal.dart';
import 'package:mobilka/features/chat/domain/pending_skill_proposal.dart';
import 'package:mobilka/features/memory/application/workspace_paths.dart';
import 'package:mobilka/features/chat/domain/pending_workspace_proposal.dart';
import 'package:mobilka/features/workspace/domain/workspace_models.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('conversation-recovery-');
    Hive.init(root.path);
    await Hive.openBox<dynamic>('conversations');
  });

  tearDown(() async {
    await Hive.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test(
    'orphan executing proposal interrupts messages and frees admission',
    () async {
      final now = DateTime(2026);
      final proposal = PendingToolProposal(
        conversationId: 'c',
        requestId: 'request',
        assistantMessageId: 'assistant',
        callOccurrence: 0,
        call: const ChatToolCall(
          id: 'call',
          name: 'write_skill',
          arguments: '{}',
        ),
        selectedAgentId: 'agent',
        allowedTools: const {'write_skill'},
        effect: ChatToolEffect.mutating,
        sourceTainted: true,
        permissionSnapshot: null,
        createdAt: now,
        state: PendingToolProposalState.executing,
      );
      final store = ConversationStore();
      await store.save(
        Conversation(
          id: 'c',
          title: 't',
          modelId: 'm',
          createdAt: now,
          updatedAt: now,
          pendingRequestMessageId: 'request',
          pendingToolProposal: proposal,
          messages: [
            ChatMessage(
              id: 'user',
              role: ChatRole.user,
              content: 'x',
              createdAt: now,
              status: ChatMessageStatus.pending,
            ),
            ChatMessage(
              id: 'assistant',
              role: ChatRole.assistant,
              content: '',
              createdAt: now,
              status: ChatMessageStatus.streaming,
              toolCalls: const [
                ChatToolCall(id: 'call', name: 'write_file', arguments: '{}'),
              ],
            ),
          ],
        ),
      );
      await store.recoverInterrupted();

      final recovered = store.loadAll().single;
      expect(
        recovered.messages.take(2).map((message) => message.status),
        everyElement(ChatMessageStatus.interrupted),
      );
      expect(
        recovered.messages.last.content,
        contains('execution_indeterminate'),
      );
      expect(recovered.pendingRequestMessageId, isNull);
      expect(recovered.pendingToolProposal, isNull);
      expect(recovered.isStreaming, isFalse);
      expect(ChatState(conversations: [recovered]).hasInFlightRequest, isFalse);
    },
  );

  test(
    'malformed workspace proposal terminalizes only its conversation',
    () async {
      final now = DateTime.utc(2026);
      final store = ConversationStore();
      final valid = Conversation(
        id: 'valid',
        title: 'valid',
        modelId: 'm',
        createdAt: now,
        updatedAt: now,
        messages: const [],
      );
      await store.save(valid);
      await conversationsBox.put('invalid', {
        ...valid.toJson(),
        'id': 'invalid',
        'pendingRequestMessageId': 'request',
        'pendingWorkspaceProposal': {
          'toolCallId': 'call',
          'toolCallIndex': 2,
          'status': 'executing',
        },
        'messages': [
          ChatMessage(
            id: 'assistant',
            role: ChatRole.assistant,
            content: '',
            createdAt: now,
            status: ChatMessageStatus.streaming,
          ).toStorageJson(),
        ],
      });

      expect(
        store.loadAll().map((conversation) => conversation.id),
        containsAll(['valid', 'invalid']),
      );
      await store.recoverInterrupted();

      final loaded = store.loadAll();
      final recovered = loaded.singleWhere(
        (conversation) => conversation.id == 'invalid',
      );
      expect(
        loaded
            .singleWhere((conversation) => conversation.id == 'valid')
            .messages,
        isEmpty,
      );
      expect(recovered.pendingWorkspaceProposal, isNull);
      expect(recovered.pendingRequestMessageId, isNull);
      expect(recovered.messages.first.status, ChatMessageStatus.interrupted);
      expect(
        recovered.messages.last.content,
        contains('workspace_recovery_invalid'),
      );
      expect(recovered.messages.last.toolCallId, 'call');
      expect(recovered.messages.last.toolCallIndex, 2);
    },
  );

  test('malformed current proposal preserves nested terminal marker', () async {
    final now = DateTime.utc(2026);
    final store = ConversationStore();
    final json = _workspaceConversation(now).toJson();
    final proposal = Map<String, dynamic>.from(
      json['pendingWorkspaceProposal'] as Map,
    );
    proposal['status'] = 'unknown';
    json['pendingWorkspaceProposal'] = proposal;
    await conversationsBox.put('workspace-c', json);

    await store.recoverInterrupted();

    final recovered = store.loadById('workspace-c')!;
    expect(recovered.pendingWorkspaceProposal, isNull);
    expect(recovered.messages.last.toolCallId, 'call');
    expect(recovered.messages.last.toolCallIndex, 0);
    expect(
      recovered.messages.last.content,
      contains('workspace_recovery_invalid'),
    );
  });

  test(
    'executing skill proposal recovery is indeterminate and never replayed',
    () async {
      final now = DateTime(2026);
      final proposal = PendingSkillProposal(
        conversationId: 'skill-c',
        requestId: 'request',
        assistantMessageId: 'assistant',
        name: 'safe',
        oldContent: null,
        proposedContent: 'candidate',
        expectedHash: null,
        sourceDerived: false,
        provenanceSummary: 'trusted_local',
        warnings: const [],
        permissionSnapshot: null,
        selectedAgentId: 'agent',
        createdAt: now,
        state: PendingSkillProposalState.executing,
      );
      final store = ConversationStore();
      await store.save(
        Conversation(
          id: 'skill-c',
          title: 't',
          modelId: 'm',
          createdAt: now,
          updatedAt: now,
          pendingRequestMessageId: 'request',
          pendingSkillProposal: proposal,
          messages: [
            ChatMessage(
              id: 'user',
              role: ChatRole.user,
              content: 'x',
              createdAt: now,
              status: ChatMessageStatus.pending,
            ),
            ChatMessage(
              id: 'assistant',
              role: ChatRole.assistant,
              content: '',
              createdAt: now,
              status: ChatMessageStatus.streaming,
            ),
          ],
        ),
      );
      await store.recoverInterrupted();
      await store.recoverInterrupted();
      final recovered = store.loadAll().single;
      expect(
        recovered.messages.take(2).map((m) => m.status),
        everyElement(ChatMessageStatus.interrupted),
      );
      expect(
        recovered.messages.where(
          (m) => m.content == 'skill_mutation_indeterminate',
        ),
        hasLength(1),
      );
      expect(recovered.pendingRequestMessageId, isNull);
      expect(recovered.pendingSkillProposal, isNull);
      expect(ChatState(conversations: [recovered]).hasInFlightRequest, isFalse);
    },
  );

  test(
    'executing workspace proposal remains blocked for startup reconciliation',
    () async {
      final now = DateTime.utc(2026);
      const content = 'new';
      const preview = 'CREATE a.txt\nnew';
      final proposal = PendingWorkspaceProposal(
        conversationId: 'workspace-c',
        requestId: 'request',
        assistantMessageId: 'assistant',
        toolCallId: 'call',
        callOccurrence: 0,
        toolCallIndex: 0,
        operation: 'write_file',
        path: 'a.txt',
        proposedContent: content,
        proposedContentHash: workspaceHash(utf8.encode(content)),
        preview: preview,
        previewHash: workspaceHash(utf8.encode(preview)),
        targetMissing: true,
        sessionKey: 'session',
        allowedTools: const {'write_file'},
        selectedAgentId: 'agent',
        workspaceBindingSnapshot: const WorkspaceBindingSnapshot(
          isContentUri: false,
          value: 'root',
          identity: 'false:root',
          rootIdentity: 'false:root',
        ),
        createdAt: now,
        expiresAt: now.add(const Duration(minutes: 15)),
        status: WorkspaceProposalStatus.executing,
        claimToken: 'c' * 43,
      );
      final store = ConversationStore();
      await store.save(
        Conversation(
          id: 'workspace-c',
          title: 't',
          modelId: 'm',
          createdAt: now,
          updatedAt: now,
          pendingRequestMessageId: 'request',
          sessionKey: 'session',
          pendingWorkspaceProposal: proposal,
          messages: [
            ChatMessage(
              id: 'assistant',
              role: ChatRole.assistant,
              content: '',
              createdAt: now,
              status: ChatMessageStatus.streaming,
              toolCalls: const [
                ChatToolCall(id: 'call', name: 'write_file', arguments: '{}'),
              ],
            ),
          ],
        ),
      );
      expect(
        store.loadById('workspace-c')?.invalidPendingWorkspaceProposal,
        isFalse,
      );
      expect(
        store.loadById('workspace-c')?.pendingWorkspaceProposal,
        isNotNull,
      );

      await store.recoverInterrupted();
      await store.recoverInterrupted();

      final recovered = store.loadAll().single;
      expect(recovered.pendingWorkspaceProposal, isNotNull);
      expect(recovered.pendingRequestMessageId, 'request');
      expect(
        recovered.messages.where(
          (message) =>
              message.content.contains('workspace_execution_indeterminate'),
        ),
        isEmpty,
      );
      expect(ChatState(conversations: [recovered]).hasInFlightRequest, isTrue);
    },
  );

  test(
    'workspace proposal context mismatches terminalize without mutation',
    () async {
      final now = DateTime.utc(2026);
      final store = ConversationStore();
      final base = _workspaceConversation(now);
      for (final mismatch in {
        'conversation': (Map<String, dynamic> json) {
          json['id'] = 'other';
        },
        'request': (Map<String, dynamic> json) {
          json['pendingRequestMessageId'] = 'other';
        },
        'session': (Map<String, dynamic> json) {
          json['sessionKey'] = 'other';
        },
        'assistant': (Map<String, dynamic> json) {
          final proposal = Map<String, dynamic>.from(
            json['pendingWorkspaceProposal'] as Map,
          );
          final context = Map<String, dynamic>.from(proposal['context'] as Map);
          context['assistantMessageId'] = 'other';
          proposal['context'] = context;
          json['pendingWorkspaceProposal'] = proposal;
        },
        'call': (Map<String, dynamic> json) {
          final messages = (json['messages'] as List).cast<Map>();
          messages.single['toolCalls'] = const [
            {
              'id': 'other',
              'type': 'function',
              'function': {'name': 'write_file', 'arguments': '{}'},
            },
          ];
        },
        'occurrence': (Map<String, dynamic> json) {
          final proposal = Map<String, dynamic>.from(
            json['pendingWorkspaceProposal'] as Map,
          );
          final context = Map<String, dynamic>.from(proposal['context'] as Map);
          context['callOccurrence'] = 1;
          context['ownerToken'] = workspaceHash(
            utf8.encode('workspace-c\u0000request\u0000call\u00001'),
          );
          proposal['context'] = context;
          json['pendingWorkspaceProposal'] = proposal;
        },
        'index': (Map<String, dynamic> json) {
          final proposal = Map<String, dynamic>.from(
            json['pendingWorkspaceProposal'] as Map,
          );
          final context = Map<String, dynamic>.from(proposal['context'] as Map);
          context['toolCallIndex'] = 1;
          proposal['context'] = context;
          json['pendingWorkspaceProposal'] = proposal;
        },
        'assistant-role': (Map<String, dynamic> json) {
          final messages = (json['messages'] as List).cast<Map>();
          messages.single['role'] = ChatRole.user.name;
        },
        'assistant-status': (Map<String, dynamic> json) {
          final messages = (json['messages'] as List).cast<Map>();
          messages.single['status'] = ChatMessageStatus.complete.name;
        },
        'duplicate-assistant': (Map<String, dynamic> json) {
          final messages = json['messages'] as List;
          messages.add(Map<String, dynamic>.from(messages.single as Map));
        },
      }.entries) {
        final json = base.toJson();
        mismatch.value(json);
        final key = 'invalid-${mismatch.key}';
        json['id'] = key;
        if (mismatch.key != 'conversation') {
          final proposal = Map<String, dynamic>.from(
            json['pendingWorkspaceProposal'] as Map,
          );
          final context = Map<String, dynamic>.from(proposal['context'] as Map);
          context['conversationId'] = key;
          proposal['context'] = context;
          json['pendingWorkspaceProposal'] = proposal;
        }
        await conversationsBox.put(key, json);
      }

      await store.recoverInterrupted();

      for (final conversation in store.loadAll()) {
        expect(conversation.pendingWorkspaceProposal, isNull);
        expect(conversation.pendingRequestMessageId, isNull);
        expect(
          conversation.messages.last.content,
          contains('workspace_recovery_invalid'),
        );
      }
    },
  );
}

Conversation _workspaceConversation(DateTime now) {
  const content = 'new';
  const preview = 'CREATE a.txt\nnew';
  return Conversation(
    id: 'workspace-c',
    title: 't',
    modelId: 'm',
    createdAt: now,
    updatedAt: now,
    pendingRequestMessageId: 'request',
    sessionKey: 'session',
    pendingWorkspaceProposal: PendingWorkspaceProposal(
      conversationId: 'workspace-c',
      requestId: 'request',
      assistantMessageId: 'assistant',
      toolCallId: 'call',
      callOccurrence: 0,
      toolCallIndex: 0,
      operation: 'write_file',
      path: 'a.txt',
      proposedContent: content,
      proposedContentHash: workspaceHash(utf8.encode(content)),
      preview: preview,
      previewHash: workspaceHash(utf8.encode(preview)),
      targetMissing: true,
      sessionKey: 'session',
      allowedTools: const {'write_file'},
      selectedAgentId: 'agent',
      workspaceBindingSnapshot: const WorkspaceBindingSnapshot(
        isContentUri: false,
        value: 'root',
        identity: 'false:root',
        rootIdentity: 'root-id',
      ),
      createdAt: now,
      expiresAt: now.add(const Duration(minutes: 15)),
    ),
    messages: [
      ChatMessage(
        id: 'assistant',
        role: ChatRole.assistant,
        content: '',
        createdAt: now,
        status: ChatMessageStatus.streaming,
        toolCalls: const [
          ChatToolCall(id: 'call', name: 'write_file', arguments: '{}'),
        ],
      ),
    ],
  );
}
