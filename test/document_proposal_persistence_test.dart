import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/core/storage/app_boxes.dart';
import 'package:mobilka/core/workspace/workspace_binding.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart';
import 'package:mobilka/features/chat/application/document_disclosure_service.dart';
import 'package:mobilka/features/chat/application/document_decision_continuation.dart';
import 'package:mobilka/features/chat/application/document_tool_runtime.dart';
import 'package:mobilka/features/chat/data/conversation_store.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/chat/domain/pending_document_proposal.dart';
import 'package:mobilka/features/documents/domain/document_snapshot.dart';
import 'package:mobilka/features/documents/domain/document_tool_request.dart';

import 'support/document_fixtures.dart';

final class _Source implements DocumentSnapshotSource {
  final snapshot = documentSnapshot(utf8.encode('name\nSECRET DOCUMENT\n'));
  @override
  Set<DocumentToolInputFormat> get supportedFormats => {
    DocumentToolInputFormat.csv,
  };
  @override
  Future<DocumentSnapshot> capture({
    required DocumentToolRequest request,
    required ChatToolExecutionContext context,
    required String requestId,
  }) async => snapshot;
}

void main() {
  late Directory root;
  late Conversation conversation;
  late PendingDocumentProposal proposal;
  final store = ConversationStore();
  final now = DateTime.utc(2026, 9, 8);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('document-persistence-');
    Hive.init(root.path);
    await Hive.openBox<dynamic>('conversations');
    final source = _Source();
    final call = ChatToolCall(
      id: 'call',
      name: 'extract_document',
      arguments: jsonEncode({
        'path': 'input.csv',
        'format': 'csv',
        'source_sha256': source.snapshot.sha256Digest,
      }),
    );
    proposal =
        await DocumentDisclosureService(
          runtime: DocumentToolRuntime(source: source),
          now: () => now,
        ).prepare(
          call: call,
          context: ChatToolExecutionContext(
            conversationId: 'conversation',
            sessionKey: 'session',
            workspaceBinding: TestWorkspaceBinding(
              testSnapshot: source.snapshot.binding,
            ),
          ),
          requestId: 'request',
          assistantMessageId: 'assistant',
          toolCallIndex: 1,
          callOccurrence: 1,
          selectedAgentId: 'agent',
          allowedTools: {'extract_document'},
        );
    conversation = Conversation(
      id: 'conversation',
      title: 'Document',
      modelId: 'model',
      createdAt: now,
      updatedAt: now,
      sessionKey: 'session',
      pendingRequestMessageId: 'request',
      pendingDocumentProposal: proposal,
      messages: [
        ChatMessage(
          id: 'request',
          role: ChatRole.user,
          content: 'read',
          createdAt: now,
        ),
        ChatMessage(
          id: 'assistant',
          role: ChatRole.assistant,
          content: '',
          createdAt: now,
          status: ChatMessageStatus.streaming,
          toolCalls: [call, call],
        ),
      ],
    );
  });

  tearDown(() async {
    await Hive.close();
    await root.delete(recursive: true);
  });

  test('round trip and copy clear preserve single authoritative proposal', () {
    final restored = Conversation.fromJson(conversation.toJson());
    expect(restored.pendingDocumentProposal!.encode(), proposal.encode());
    expect(
      restored.copyWith(title: 'Renamed').pendingDocumentProposal,
      isNotNull,
    );
    expect(
      restored
          .copyWith(clearPendingDocumentProposal: true)
          .pendingDocumentProposal,
      isNull,
    );
  });

  test(
    'pending survives repeated restart without history disclosure',
    () async {
      await store.save(conversation);
      await store.recoverInterrupted();
      await store.recoverInterrupted();
      final restored = store.loadById(conversation.id)!;
      expect(
        restored.pendingDocumentProposal!.status,
        DocumentProposalStatus.pending,
      );
      expect(restored.pendingRequestMessageId, 'request');
      expect(
        restored.messages.any((m) => m.content.contains('SECRET DOCUMENT')),
        isFalse,
      );
    },
  );

  test('interrupted claim resets pending without approving', () async {
    await store.save(
      conversation.copyWith(
        pendingDocumentProposal: proposal.claim('token', now),
      ),
    );
    await store.recoverInterrupted();
    final restored = store.loadById(conversation.id)!;
    expect(
      restored.pendingDocumentProposal!.status,
      DocumentProposalStatus.pending,
    );
    expect(restored.pendingDocumentProposal!.claimToken, isNull);
    expect(restored.messages.where((m) => m.role == ChatRole.tool), isEmpty);
  });

  test('already committed exact result clears proposal idempotently', () async {
    await store.save(
      conversation.copyWith(
        pendingDocumentProposal: proposal.claim('token', now),
        messages: [
          ...conversation.messages,
          ChatMessage(
            id: 'result',
            role: ChatRole.tool,
            content: proposal.payload,
            createdAt: now,
            toolCallId: 'call',
            toolCallIndex: 1,
          ),
        ],
      ),
    );
    await store.recoverInterrupted();
    await store.recoverInterrupted();
    final restored = store.loadById(conversation.id)!;
    expect(restored.pendingDocumentProposal, isNull);
    expect(
      restored.messages.where((m) => m.role == ChatRole.tool).single.content,
      proposal.payload,
    );
  });

  test(
    'malformed proposal preserves conversation and never restores its text',
    () async {
      final other = Conversation(
        id: 'other',
        title: 'Other',
        modelId: 'model',
        createdAt: now,
        updatedAt: now,
        messages: const [],
      );
      await store.save(other);
      for (final raw in <Object>[
        'not a map',
        {...proposal.toJson(), 'status': 'unknown'},
        {...proposal.toJson(), 'conversationId': 'other'},
        {...proposal.toJson(), 'toolCallIndex': 0, 'callOccurrence': 0},
        {...proposal.toJson(), 'binding': 'malformed'},
        {...proposal.toJson(), 'payloadSha256': '0' * 64},
      ]) {
        final data = {...conversation.toJson(), 'pendingDocumentProposal': raw};
        // Index zero is a different duplicate occurrence, so use a mismatched ID.
        if (raw is Map && raw['toolCallIndex'] == 0) {
          raw['toolCallId'] = 'other';
        }
        await conversationsBox.put(conversation.id, data);
        final decoded = store.loadById(conversation.id)!;
        expect(decoded.invalidPendingDocumentProposal, isTrue);
        expect(decoded.pendingDocumentProposal, isNull);
        expect(
          jsonEncode(decoded.toJson()),
          isNot(contains('SECRET DOCUMENT')),
        );
        await store.recoverInterrupted();
        final recovered = store.loadById(conversation.id)!;
        expect(
          recovered.messages.last.content,
          '{"error":"document_disclosure_invalid"}',
        );
        expect(recovered.pendingDocumentProposal, isNull);
        expect(store.loadById('other')!.title, 'Other');
      }
    },
  );

  for (final boundary in ['different-id', 'same-id', 'user']) {
    test('committed result preserves later $boundary segment', () async {
      final laterId = boundary == 'different-id' ? 'other-call' : 'call';
      final later = [
        ChatMessage(
          id: 'boundary',
          role: boundary == 'user' ? ChatRole.user : ChatRole.assistant,
          content: 'later round',
          createdAt: now,
          toolCalls: boundary == 'user'
              ? const []
              : [
                  ChatToolCall(
                    id: laterId,
                    name: 'extract_document',
                    arguments: proposal.arguments,
                  ),
                ],
        ),
        ChatMessage(
          id: 'later-result',
          role: ChatRole.tool,
          content: 'UNRELATED RESULT',
          createdAt: now,
          toolCallId: laterId,
          toolCallIndex: 1,
        ),
      ];
      await store.save(
        conversation.copyWith(
          pendingDocumentProposal: proposal.claim('token', now),
          messages: [
            ...conversation.messages,
            ChatMessage(
              id: 'approved',
              role: ChatRole.tool,
              content: proposal.payload,
              createdAt: now,
              toolCallId: 'call',
              toolCallIndex: 1,
            ),
            ...later,
          ],
        ),
      );
      await store.recoverInterrupted();
      final restored = store.loadById(conversation.id)!;
      expect(restored.pendingDocumentProposal, isNull);
      expect(
        restored.messages.firstWhere((m) => m.id == 'approved').content,
        proposal.payload,
      );
      expect(
        restored.messages.skip(3).map((m) => m.toStorageJson()).toList(),
        later.map((m) => m.toStorageJson()).toList(),
      );
    });
  }

  test(
    'wrong result ID at same index is not overwritten or accepted',
    () async {
      await store.save(
        conversation.copyWith(
          pendingDocumentProposal: proposal.claim('token', now),
          messages: [
            ...conversation.messages,
            ChatMessage(
              id: 'wrong-id',
              role: ChatRole.tool,
              content: 'OTHER TOOL CONTENT',
              createdAt: now,
              toolCallId: 'other',
              toolCallIndex: 1,
            ),
          ],
        ),
      );
      await store.recoverInterrupted();
      final restored = store.loadById(conversation.id)!;
      expect(restored.pendingDocumentProposal, isNull);
      expect(restored.pendingRequestMessageId, isNull);
      expect(
        restored.messages.firstWhere((m) => m.id == 'wrong-id').content,
        'OTHER TOOL CONTENT',
      );
      expect(
        restored.messages.last.content,
        '{"error":"document_disclosure_invalid"}',
      );
    },
  );

  test(
    'missing duplicate index fails closed only within owning segment',
    () async {
      await store.save(
        conversation.copyWith(
          pendingDocumentProposal: proposal.claim('token', now),
          messages: [
            ...conversation.messages,
            ChatMessage(
              id: 'ambiguous',
              role: ChatRole.tool,
              content: proposal.payload,
              createdAt: now,
              toolCallId: 'call',
            ),
            ChatMessage(
              id: 'next',
              role: ChatRole.assistant,
              content: '',
              createdAt: now,
            ),
            ChatMessage(
              id: 'unrelated',
              role: ChatRole.tool,
              content: 'KEEP',
              createdAt: now,
              toolCallId: 'call',
            ),
          ],
        ),
      );
      await store.recoverInterrupted();
      final restored = store.loadById(conversation.id)!;
      expect(restored.pendingDocumentProposal, isNull);
      expect(
        restored.messages.firstWhere((m) => m.id == 'ambiguous').content,
        '{"error":"document_disclosure_invalid"}',
      );
      expect(
        restored.messages.firstWhere((m) => m.id == 'unrelated').content,
        'KEEP',
      );
    },
  );

  test(
    'conflicting terminal output is replaced with safe invalid result',
    () async {
      await store.save(
        conversation.copyWith(
          pendingDocumentProposal: proposal.claim('token', now),
          messages: [
            ...conversation.messages,
            ChatMessage(
              id: 'bad-result',
              role: ChatRole.tool,
              content: 'SECRET DOCUMENT mismatch',
              createdAt: now,
              toolCallId: 'call',
              toolCallIndex: 1,
            ),
          ],
        ),
      );
      await store.recoverInterrupted();
      final restored = store.loadById(conversation.id)!;
      expect(restored.pendingDocumentProposal, isNull);
      expect(
        restored.messages.any((m) => m.content.contains('SECRET DOCUMENT')),
        isFalse,
      );
    },
  );

  test(
    'continuation inserts selected result before indexed deferred calls',
    () async {
      final duplicate = conversation.messages[1].toolCalls[1];
      final laterMutation = ChatToolCall(
        id: 'mutation',
        name: 'write_file',
        arguments: '{"path":"later"}',
      );
      final laterDocument = ChatToolCall(
        id: duplicate.id,
        name: duplicate.name,
        arguments: duplicate.arguments,
      );
      conversation = conversation.copyWith(
        pendingDocumentProposal: proposal.claim('token', now),
        messages: [
          conversation.messages.first,
          conversation.messages[1].copyWith(
            toolCalls: [
              ...conversation.messages[1].toolCalls,
              laterMutation,
              laterDocument,
            ],
          ),
          ChatMessage(
            id: 'before',
            role: ChatRole.tool,
            content: '{"ok":true}',
            createdAt: now,
            toolCallId: duplicate.id,
            toolCallIndex: 0,
          ),
          ChatMessage(
            id: 'deferred-mutation',
            role: ChatRole.tool,
            content: '{"error":"deferred_pending_confirmation"}',
            createdAt: now,
            toolCallId: laterMutation.id,
            toolCallIndex: 2,
          ),
          ChatMessage(
            id: 'deferred-document',
            role: ChatRole.tool,
            content: '{"error":"deferred_pending_confirmation"}',
            createdAt: now,
            toolCallId: laterDocument.id,
            toolCallIndex: 3,
          ),
        ],
      );
      final resumed =
          await DocumentDecisionContinuation(
            persistMutation: (_, mutation) async {
              final updated = mutation(conversation);
              if (updated != null) conversation = updated;
              return updated;
            },
          ).continueRequest(
            conversation: conversation,
            proposal: conversation.pendingDocumentProposal!,
            toolResult: proposal.payload,
            binding: const TestWorkspaceBinding(),
          );
      final results = conversation.messages
          .skip(2)
          .takeWhile((message) => message.role == ChatRole.tool)
          .toList();
      expect(results.map((message) => message.toolCallIndex), [0, 1, 2, 3]);
      expect(results[1].content, proposal.payload);
      expect(
        results.skip(2).map((message) => message.content),
        everyElement('{"error":"deferred_pending_confirmation"}'),
      );
      expect(resumed, isNotNull);
      expect(
        resumed!.history
            .where((message) => message.role == ChatRole.tool)
            .map((message) => message.toolCallIndex),
        [0, 1, 2, 3],
      );
    },
  );
}
