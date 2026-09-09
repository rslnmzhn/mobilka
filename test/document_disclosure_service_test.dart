import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/core/workspace/workspace_binding.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart';
import 'package:mobilka/features/chat/application/document_disclosure_service.dart';
import 'package:mobilka/features/chat/application/document_tool_runtime.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/pending_document_proposal.dart';
import 'package:mobilka/features/documents/domain/document_limits.dart';
import 'package:mobilka/features/documents/domain/document_snapshot.dart';
import 'package:mobilka/features/documents/domain/document_tool_request.dart';

import 'support/document_fixtures.dart';

final class _Source implements DocumentSnapshotSource {
  _Source(this.snapshot);
  DocumentSnapshot snapshot;
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
  late _Source source;
  late DocumentDisclosureService service;
  late ChatToolCall call;
  late ChatToolExecutionContext context;
  late DateTime now;
  const tools = {'extract_document'};

  setUp(() {
    now = DateTime.utc(2026, 9, 8);
    source = _Source(documentSnapshot(utf8.encode('name\nPRIVATE TEXT\n')));
    context = ChatToolExecutionContext(
      conversationId: 'conversation',
      sessionKey: 'session',
      workspaceBinding: TestWorkspaceBinding(
        testSnapshot: source.snapshot.binding,
      ),
    );
    call = ChatToolCall(
      id: 'call',
      name: 'extract_document',
      arguments: jsonEncode({
        'path': 'input.csv',
        'source_sha256': source.snapshot.sha256Digest,
        'format': 'csv',
      }),
    );
    service = DocumentDisclosureService(
      runtime: DocumentToolRuntime(source: source),
      now: () => now,
    );
  });

  Future<PendingDocumentProposal> prepare() => service.prepare(
    call: call,
    context: context,
    requestId: 'request',
    assistantMessageId: 'assistant',
    toolCallIndex: 1,
    callOccurrence: 0,
    selectedAgentId: 'agent',
    allowedTools: tools,
  );
  Future<String> confirm(
    PendingDocumentProposal proposal, {
    String agent = 'agent',
    Set<String> permissions = tools,
    String request = 'request',
    int index = 1,
    int occurrence = 0,
  }) => service.confirm(
    proposal: proposal,
    claimToken: 'claim',
    call: call,
    context: context,
    requestId: request,
    assistantMessageId: 'assistant',
    toolCallIndex: index,
    callOccurrence: occurrence,
    selectedAgentId: agent,
    allowedTools: permissions,
  );

  test('real CSV produces exact bounded payload and durable claim', () async {
    final proposal = await prepare();
    expect(proposal.payload, contains('PRIVATE TEXT'));
    expect(
      proposal.payloadSha256,
      PendingDocumentProposal.digest(proposal.payload),
    );
    expect(
      utf8.encode(proposal.payload).length,
      lessThanOrEqualTo(1024 * 1024),
    );
    expect(proposal.toJson().keys, isNot(contains('bytes')));
    final restored = PendingDocumentProposal.decode(proposal.encode());
    expect(restored.encode(), proposal.encode());
    final claimed = PendingDocumentProposal.decode(
      restored.claim('claim', now).encode(),
    );
    expect(await confirm(claimed), proposal.payload);
    expect(await confirm(claimed), proposal.payload);
    expect(service.reject(), DocumentDisclosureService.rejectionPayload);
    expect(service.reject(), isNot(contains('PRIVATE TEXT')));
  });

  test('pending without caller claim cannot disclose', () async {
    await expectLater(
      confirm(await prepare()),
      throwsA(isA<DocumentException>()),
    );
  });

  test(
    'agent permissions request index and occurrence must remain exact',
    () async {
      final proposal = (await prepare()).claim('claim', now);
      for (final future in [
        () => confirm(proposal, agent: 'other'),
        () => confirm(proposal, permissions: {}),
        () => confirm(proposal, request: 'other'),
        () => confirm(proposal, index: 2),
        () => confirm(proposal, occurrence: 1),
      ]) {
        await expectLater(future(), throwsA(isA<DocumentException>()));
      }
    },
  );

  test('expiry is checked at confirmation', () async {
    final proposal = (await prepare()).claim('claim', now);
    now = proposal.expiresAt;
    await expectLater(confirm(proposal), throwsA(isA<DocumentException>()));
  });

  test('fresh changed bytes fail closed', () async {
    final proposal = (await prepare()).claim('claim', now);
    source.snapshot = documentSnapshot(utf8.encode('name\nCHANGED\n'));
    await expectLater(confirm(proposal), throwsA(isA<DocumentException>()));
  });

  test('fresh root and source owner are checked', () async {
    final proposal = (await prepare()).claim('claim', now);
    final original = source.snapshot;
    for (final changeRoot in [true, false]) {
      source.snapshot = DocumentSnapshot(
        documentId: original.documentId,
        conversationId: changeRoot ? original.conversationId : 'other',
        requestId: original.requestId,
        sessionKey: original.sessionKey,
        binding: changeRoot
            ? original.binding.withRootIdentity('other-root')
            : original.binding,
        sourcePath: original.sourcePath.value,
        sourceIdentity: original.sourceIdentity,
        bytes: original.bytes,
      );
      await expectLater(confirm(proposal), throwsA(isA<DocumentException>()));
    }
  });

  test(
    'strict persisted decoding rejects malformed fields and payload',
    () async {
      final proposal = await prepare();
      final invalid = <Map<String, Object?>>[
        {...proposal.toJson(), 'extra': true},
        {...proposal.toJson(), 'version': 2},
        {...proposal.toJson(), 'status': 'executing'},
        {...proposal.toJson(), 'payload': '{}'},
        {...proposal.toJson(), 'payload': 'x' * (1024 * 1024 + 1)},
        {...proposal.toJson(), 'sourceHash': 'bad'},
        {...proposal.toJson(), 'callOccurrence': 2},
        {...proposal.toJson(), 'claimedAt': now.toIso8601String()},
      ];
      for (final data in invalid) {
        expect(
          () => PendingDocumentProposal.fromJson(data),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              PendingDocumentProposal.invalidProposal,
            ),
          ),
        );
      }
      expect(
        () => PendingDocumentProposal.decode('{"version":1,"version":1}'),
        throwsFormatException,
      );
      expect(
        () => PendingDocumentProposal.decode(
          'x' * (PendingDocumentProposal.maxStorageBytes + 1),
        ),
        throwsFormatException,
      );
    },
  );
}
