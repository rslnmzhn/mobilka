import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/workspace_paths.dart';
import 'package:mobilka/features/chat/application/workspace_chat_tool_adapter.dart';
import 'package:mobilka/features/workspace/application/session_workspace_authority.dart';
import 'package:mobilka/features/workspace/application/session_workspace_boundary.dart';
import 'package:mobilka/features/workspace/application/workspace_mutation_coordinator.dart';
import 'package:mobilka/features/chat/domain/pending_workspace_proposal.dart';
import 'package:mobilka/features/workspace/domain/session_workspace_path.dart';
import 'package:mobilka/features/workspace/domain/workspace_models.dart';
import 'package:synchronized/synchronized.dart';

void main() {
  test(
    'write_session_notes is an always-confirm compatibility alias',
    () async {
      final runtime = WorkspaceChatToolRuntime(
        agentTools: (_) async => const {'write_session_notes'},
      );
      final now = DateTime.now().toUtc();
      final proposal = PendingWorkspaceProposal(
        conversationId: 'conversation',
        requestId: 'request',
        assistantMessageId: 'assistant',
        toolCallId: 'notes',
        callOccurrence: 0,
        toolCallIndex: 0,
        operation: 'write_file',
        path: 'session.md',
        proposedContent: '# Summary',
        proposedContentHash: _hash('# Summary'),
        preview: 'CREATE session.md\n# Summary',
        previewHash: _hash('CREATE session.md\n# Summary'),
        targetMissing: true,
        sessionKey: 'session',
        allowedTools: const {'write_session_notes'},
        selectedAgentId: 'agent',
        workspaceBindingSnapshot: const WorkspaceBindingSnapshot(
          isContentUri: false,
          value: 'root',
          identity: 'root',
          rootIdentity: 'root',
        ),
        createdAt: now,
        expiresAt: now.add(const Duration(minutes: 15)),
      );

      expect(proposal.operation, 'write_file');
      expect(proposal.path, 'session.md');
      expect(proposal.proposedContent, '# Summary');
      expect(proposal.allowedTools, const {'write_session_notes'});
      expect(proposal.status, WorkspaceProposalStatus.pending);
      await runtime.revalidateWorkspacePermission(
        proposal: proposal,
        selectedAgentId: 'agent',
        allowedTools: const {'write_session_notes'},
      );
    },
  );

  test('workspace mutations reject every portable spelling of artifacts', () {
    final now = DateTime.now().toUtc();
    for (final path in ['artifacts/result.md', 'Artifacts/result.md']) {
      final preview = 'CREATE $path\nchanged';
      expect(
        () => PendingWorkspaceProposal(
          conversationId: 'conversation',
          requestId: 'request',
          assistantMessageId: 'assistant',
          toolCallId: 'write',
          callOccurrence: 0,
          toolCallIndex: 0,
          operation: 'write_file',
          path: path,
          proposedContent: 'changed',
          proposedContentHash: _hash('changed'),
          preview: preview,
          previewHash: _hash(preview),
          targetMissing: true,
          sessionKey: 'session',
          allowedTools: const {'write_file'},
          selectedAgentId: 'agent',
          workspaceBindingSnapshot: const WorkspaceBindingSnapshot(
            isContentUri: false,
            value: 'root',
            identity: 'root',
            rootIdentity: 'root',
          ),
          createdAt: now,
          expiresAt: now.add(const Duration(minutes: 15)),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'workspace_artifacts_read_only',
          ),
        ),
      );
    }
  });

  test(
    'search reads chunks through EOF and finds matches after 256 KiB',
    () async {
      final content = '${'a' * (workspaceMaxReadBytes + 3)}\nlate needle\n';
      final boundary = _ChunkBoundary(content);
      final authority = SessionWorkspaceAuthority(
        conversationId: 'conversation',
        requestId: 'request',
        sessionKey: 'session',
        binding: const WorkspaceBinding.fakeForTest(),
        rootIdentity: 'root',
        boundary: boundary,
      );

      final result = await authority.searchFiles('needle');

      expect(result.matches.single['line'], 2);
      expect(boundary.readCount, greaterThan(1));
    },
  );

  test('readEntireFile preserves the tail beyond one read chunk', () async {
    final content = '${'x' * (workspaceMaxReadBytes + 11)}TAIL';
    final boundary = _ChunkBoundary(content);
    final authority = SessionWorkspaceAuthority(
      conversationId: 'conversation',
      requestId: 'request',
      sessionKey: 'session',
      binding: const WorkspaceBinding.fakeForTest(),
      rootIdentity: 'root',
      boundary: boundary,
    );

    final read = await authority.readEntireFile('large.txt');

    expect(read.content, content);
    expect(read.truncated, isFalse);
    expect(boundary.readCount, greaterThan(1));
  });

  test('readEntireFile rejects over one MiB before reading', () async {
    final boundary = _ChunkBoundary('x' * (workspaceMaxTextBytes + 1));
    final authority = SessionWorkspaceAuthority(
      conversationId: 'conversation',
      requestId: 'request',
      sessionKey: 'session',
      binding: const WorkspaceBinding.fakeForTest(),
      rootIdentity: 'root',
      boundary: boundary,
    );

    await expectLater(
      authority.readEntireFile('large.txt'),
      throwsA(isA<WorkspaceBoundaryException>()),
    );
    expect(boundary.readCount, 0);
  });

  test(
    'search skips artifacts, binary, oversized, and unknown metadata',
    () async {
      final boundary = _SearchBoundary();
      final authority = SessionWorkspaceAuthority(
        conversationId: 'conversation',
        requestId: 'request',
        sessionKey: 'session',
        binding: const WorkspaceBinding.fakeForTest(),
        rootIdentity: 'root',
        boundary: boundary,
      );

      final result = await authority.searchFiles('needle');

      expect(result.matches.single['path'], 'good.txt');
      expect(
        result.skipped,
        contains(containsPair('reason', 'metadata_unavailable')),
      );
      expect(
        result.skipped,
        contains(containsPair('reason', 'unsupported_text')),
      );
      expect(
        result.skipped,
        contains(containsPair('reason', 'workspace_file_too_large')),
      );
      expect(boundary.readPaths, isNot(contains('Artifacts/report.docx')));
      expect(result.toJson()['skipped_count'], 3);
      expect(result.truncated, isFalse);
    },
  );

  test('root replacement blocks reads before recovery', () async {
    final boundary = _ChunkBoundary('content')..root = 'replacement';
    var recovered = false;
    final authority = SessionWorkspaceAuthority(
      conversationId: 'conversation',
      requestId: 'request',
      sessionKey: 'session',
      binding: const WorkspaceBinding.fakeForTest(),
      rootIdentity: 'root',
      boundary: boundary,
      recover: (_) async => recovered = true,
    );

    await expectLater(
      authority.readFile('large.txt'),
      throwsA(
        isA<WorkspaceBoundaryException>().having(
          (error) => error.code,
          'code',
          'workspace_binding_changed',
        ),
      ),
    );
    expect(recovered, isFalse);
    expect(boundary.readCount, 0);
  });

  test(
    'initial binding without root identity blocks reads on pending recovery',
    () async {
      final boundary = _ChunkBoundary('content');
      final authority = SessionWorkspaceAuthority(
        conversationId: 'conversation',
        requestId: 'request',
        sessionKey: 'session',
        binding: const TestWorkspaceBinding(
          testSnapshot: WorkspaceBindingSnapshot(
            isContentUri: false,
            value: 'root',
            identity: 'location-only',
          ),
        ),
        rootIdentity: await boundary.rootIdentity(),
        boundary: boundary,
        recover: (_) async => throw const WorkspaceRecoveryPendingException(
          'workspace_recovery_pending',
        ),
      );

      await expectLater(
        authority.readFile('large.txt'),
        throwsA(isA<WorkspaceRecoveryPendingException>()),
      );
      expect(boundary.readCount, 0);
    },
  );
}

String _hash(String value) {
  final bytes = utf8.encode(value);
  return workspaceHash(bytes);
}

final class _ChunkBoundary implements SessionWorkspaceBoundary {
  _ChunkBoundary(String content) : bytes = utf8.encode(content);
  final List<int> bytes;
  final Lock lock = Lock();
  int readCount = 0;
  String root = 'root';

  @override
  Future<String> rootIdentity() async => root;

  WorkspaceEntry get entry => WorkspaceEntry(
    path: 'large.txt',
    type: WorkspaceEntryType.file,
    size: bytes.length,
    identity: 'file:large.txt',
    sha256: workspaceHash(bytes),
  );

  @override
  Future<T> synchronized<T>(Future<T> Function() action) =>
      lock.synchronized(action);

  @override
  Future<List<WorkspaceEntry>> list(
    SessionWorkspacePath path, {
    required bool recursive,
  }) async => [entry];

  @override
  Future<WorkspaceEntry?> metadata(SessionWorkspacePath path) async => entry;

  @override
  Future<WorkspaceReadResult> read(
    SessionWorkspacePath path, {
    required int offset,
    required int maxBytes,
  }) async {
    readCount++;
    var end = (offset + maxBytes).clamp(offset, bytes.length);
    while (end > offset && end < bytes.length && (bytes[end] & 0xc0) == 0x80) {
      end--;
    }
    return WorkspaceReadResult(
      content: utf8.decode(bytes.sublist(offset, end)),
      size: bytes.length,
      sha256: workspaceHash(bytes),
      nextOffset: end,
      truncated: end < bytes.length,
      identity: entry.identity,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _SearchBoundary implements SessionWorkspaceBoundary {
  final readPaths = <String>[];

  @override
  Future<String> rootIdentity() async => 'root';

  @override
  Future<T> synchronized<T>(Future<T> Function() action) => action();

  @override
  Future<List<WorkspaceEntry>> list(
    SessionWorkspacePath path, {
    required bool recursive,
  }) async => const [
    WorkspaceEntry(
      path: 'good.txt',
      type: WorkspaceEntryType.file,
      size: 12,
      identity: 'good',
    ),
    WorkspaceEntry(
      path: 'cloud.txt',
      type: WorkspaceEntryType.file,
      size: null,
      identity: 'cloud',
    ),
    WorkspaceEntry(
      path: 'binary.docx',
      type: WorkspaceEntryType.file,
      size: 4,
      identity: 'binary',
    ),
    WorkspaceEntry(
      path: 'huge.txt',
      type: WorkspaceEntryType.file,
      size: workspaceMaxTextBytes + 1,
      identity: 'huge',
    ),
    WorkspaceEntry(
      path: 'Artifacts/report.docx',
      type: WorkspaceEntryType.file,
      size: 12 * 1024 * 1024,
      identity: 'artifact',
    ),
  ];

  @override
  Future<WorkspaceReadResult> read(
    SessionWorkspacePath path, {
    required int offset,
    required int maxBytes,
  }) async {
    readPaths.add(path.value);
    if (path.value == 'binary.docx') {
      throw const WorkspaceBoundaryException('unsupported_text');
    }
    return WorkspaceReadResult(
      content: 'find needle',
      size: 12,
      sha256: workspaceHash(utf8.encode('find needle')),
      nextOffset: 12,
      truncated: false,
      identity: 'good',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
