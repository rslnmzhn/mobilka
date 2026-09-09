import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/core/workspace/workspace_binding.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart';
import 'package:mobilka/features/chat/application/document_tool_runtime.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/documents/application/document_tool_service.dart';
import 'package:mobilka/features/documents/domain/document_limits.dart';
import 'package:mobilka/features/documents/domain/document_snapshot.dart';
import 'package:mobilka/features/documents/domain/document_tool_request.dart';

import 'support/document_fixtures.dart';

final class _Source implements DocumentSnapshotSource {
  _Source(this.snapshot);

  final DocumentSnapshot snapshot;
  int captures = 0;

  @override
  Set<DocumentToolInputFormat> get supportedFormats =>
      DocumentToolInputFormat.values.toSet();

  @override
  Future<DocumentSnapshot> capture({
    required DocumentToolRequest request,
    required ChatToolExecutionContext context,
    required String requestId,
  }) async {
    captures++;
    return snapshot;
  }
}

void main() {
  const allowed = {'extract_document', 'ocr_document'};
  final snapshot = documentSnapshot(utf8.encode('name\nLOCAL SECRET\n'));
  final call = ChatToolCall(
    id: 'call',
    name: 'extract_document',
    arguments: jsonEncode({
      'path': 'input.csv',
      'source_sha256': snapshot.sha256Digest,
      'format': 'csv',
    }),
  );
  ChatToolExecutionContext context({String owner = 'conversation'}) =>
      ChatToolExecutionContext(
        conversationId: owner,
        sessionKey: 'session',
        workspaceBinding: TestWorkspaceBinding(testSnapshot: snapshot.binding),
      );

  test('unconfigured production source advertises nothing', () async {
    expect(await DocumentToolRuntime().availableTools(allowed), isEmpty);
  });

  test('schemas exclude native formats without actual readiness', () async {
    final runtime = DocumentToolRuntime(source: _Source(snapshot));
    final tools = await runtime.availableTools(allowed);
    expect(tools.map((tool) => tool.name), ['extract_document']);
    expect(tools.single.effect, ChatToolEffect.runtimeConfirmed);
    final properties = tools.single.parameters['properties'] as Map;
    expect((properties['format'] as Map)['enum'], ['csv', 'docx', 'xlsx']);
    expect(await runtime.availableTools({}), isEmpty);
  });

  test('execute bypass never captures or discloses local text', () async {
    final source = _Source(snapshot);
    final runtime = DocumentToolRuntime(source: source);
    expect(
      await runtime.executeTool(call, allowed, context: context()),
      DocumentToolRuntime.requiresConfirmation,
    );
    expect(source.captures, 0);
  });

  test('explicit local preparation uses the real CSV extractor', () async {
    final runtime = DocumentToolRuntime(source: _Source(snapshot));
    final result = await runtime.prepareLocalResult(
      call: call,
      allowedTools: allowed,
      context: context(),
      requestId: 'request',
    );
    expect(result, isA<ExtractedDocumentToolResult>());
    expect(
      (result as ExtractedDocumentToolResult).extraction.fragments.map(
        (fragment) => fragment.text,
      ),
      contains('LOCAL SECRET'),
    );
  });

  test('cross-owner capture fails before extraction', () async {
    final runtime = DocumentToolRuntime(source: _Source(snapshot));
    await expectLater(
      runtime.prepareLocalResult(
        call: call,
        allowedTools: allowed,
        context: context(owner: 'other'),
        requestId: 'request',
      ),
      throwsA(
        isA<DocumentException>().having(
          (error) => error.code,
          'code',
          'document_source_owner_mismatch',
        ),
      ),
    );
  });

  test('revoked tool permission does not acquire source bytes', () async {
    final source = _Source(snapshot);
    final runtime = DocumentToolRuntime(source: source);
    await expectLater(
      runtime.prepareLocalResult(
        call: call,
        allowedTools: {},
        context: context(),
        requestId: 'request',
      ),
      throwsA(isA<DocumentException>()),
    );
    expect(source.captures, 0);
  });
}
