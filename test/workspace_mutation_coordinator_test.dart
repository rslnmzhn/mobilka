import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/workspace_paths.dart';
import 'package:mobilka/features/workspace/application/session_workspace_boundary.dart';
import 'package:mobilka/features/workspace/application/workspace_mutation_coordinator.dart';
import 'package:mobilka/features/workspace/data/workspace_recovery_journal.dart';
import 'package:mobilka/features/chat/domain/pending_workspace_proposal.dart';
import 'package:mobilka/features/workspace/domain/workspace_models.dart';

import 'support/workspace_mutation_boundary_fake.dart';

void main() {
  group('WorkspaceMutationCoordinator', () {
    late MemoryWorkspaceBoundaryFake boundary;
    late InMemoryWorkspaceRecoveryJournal journal;
    late WorkspaceMutationCoordinator coordinator;

    setUp(() {
      boundary = MemoryWorkspaceBoundaryFake();
      journal = InMemoryWorkspaceRecoveryJournal();
      coordinator = WorkspaceMutationCoordinator(
        rootIdentity: 'root',
        sessionKey: 'session',
        boundary: boundary,
        journal: journal,
      );
    });

    test('commits create only after an executing proposal', () async {
      final proposal = _proposal('write_file', path: 'a.txt', content: 'new');
      await expectLater(
        coordinator.commit(
          identity: proposal.identity,
          ownerToken: proposal.context.ownerToken,
          proposedContent: proposal.proposedContent,
          expiresAt: proposal.expiresAt,
          claimToken: proposal.claimToken ?? '',
          revalidateAuthorization: () async {},
        ),
        throwsA(isA<StateError>()),
      );
      expect(boundary.files, isEmpty);

      final result = await _claimAndCommit(coordinator, proposal);
      expect(result.outcome, WorkspaceMutationOutcome.committed);
      expect(utf8.decode(boundary.files['a.txt']!), 'new');
      expect(journal.records, hasLength(1));
      expect(boundary.prepared, hasLength(1));
      await coordinator.acknowledgeOutcome(result.operationId, result.token);
      expect(journal.records, isEmpty);
      expect(boundary.prepared, isEmpty);
      expect(boundary.maxLockDepth, 1);
    });

    test(
      'artifact subtree bytes and entries do not consume workspace quota',
      () async {
        boundary.files['Artifacts/report.docx'] = List<int>.filled(
          12 * 1024 * 1024,
          0,
        );

        final result = await _claimAndCommit(
          coordinator,
          _proposal('write_file', path: 'notes.txt', content: 'ok'),
        );

        expect(result.outcome, WorkspaceMutationOutcome.committed);
        expect(utf8.decode(boundary.files['notes.txt']!), 'ok');
      },
    );

    test('commits replace, patch result, move, delete, and mkdir', () async {
      boundary.seed('a.txt', 'old');
      await _commitAndAcknowledge(
        coordinator,
        _proposal(
          'write_file',
          path: 'a.txt',
          content: 'replace',
          source: boundary.entry('a.txt'),
        ),
      );
      expect(utf8.decode(boundary.files['a.txt']!), 'replace');

      await _commitAndAcknowledge(
        coordinator,
        _proposal(
          'apply_patch',
          path: 'a.txt',
          content: 'patched',
          source: boundary.entry('a.txt'),
        ),
      );
      expect(utf8.decode(boundary.files['a.txt']!), 'patched');

      await _commitAndAcknowledge(
        coordinator,
        _proposal(
          'move_file',
          path: 'a.txt',
          destination: 'b.txt',
          source: boundary.entry('a.txt'),
        ),
      );
      expect(boundary.files.containsKey('a.txt'), isFalse);
      expect(utf8.decode(boundary.files['b.txt']!), 'patched');

      await _commitAndAcknowledge(
        coordinator,
        _proposal(
          'delete_file',
          path: 'b.txt',
          source: boundary.entry('b.txt'),
        ),
      );
      expect(boundary.files, isEmpty);

      await _commitAndAcknowledge(
        coordinator,
        _proposal('make_directory', path: 'docs'),
      );
      expect(boundary.directories, contains('docs'));
    });

    test('rejects stale source, destination, binding, and expiry', () async {
      boundary.seed('a.txt', 'old');
      final source = boundary.entry('a.txt');
      boundary.seed('a.txt', 'changed');
      await expectLater(
        _claimAndCommit(
          coordinator,
          _proposal(
            'write_file',
            path: 'a.txt',
            content: 'new',
            source: source,
          ),
        ),
        throwsA(isA<StateError>()),
      );
      boundary.seed('b.txt', 'occupied');
      await expectLater(
        _claimAndCommit(
          coordinator,
          _proposal(
            'move_file',
            path: 'a.txt',
            destination: 'b.txt',
            source: boundary.entry('a.txt'),
          ),
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        _claimAndCommit(
          coordinator,
          _proposal('write_file', path: 'c.txt', content: 'x', root: 'other'),
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        _claimAndCommit(
          coordinator,
          _proposal('write_file', path: 'c.txt', content: 'x', expired: true),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'revalidates authorization inside lock immediately before prepare',
      () async {
        final proposal = _proposal('write_file', path: 'a.txt', content: 'new');
        final token = await coordinator.beginClaim(
          proposal.identity,
          proposal.workspaceBindingSnapshot,
          proposal.context.ownerToken,
        );
        boundary.onPrepare = () =>
            expect(boundary.authorizationChecked, isTrue);

        await coordinator.commit(
          identity: proposal.identity,
          ownerToken: proposal.context.ownerToken,
          proposedContent: proposal.proposedContent,
          expiresAt: proposal.expiresAt,
          claimToken: token,
          revalidateAuthorization: () async {
            expect(boundary.lockDepth, 1);
            expect(boundary.prepared, isEmpty);
            boundary.authorizationChecked = true;
          },
        );

        expect(boundary.authorizationChecked, isTrue);
      },
    );

    test('revoked authorization aborts before native prepare', () async {
      final proposal = _proposal('write_file', path: 'a.txt', content: 'new');
      final token = await coordinator.beginClaim(
        proposal.identity,
        proposal.workspaceBindingSnapshot,
        proposal.context.ownerToken,
      );

      await expectLater(
        coordinator.commit(
          identity: proposal.identity,
          ownerToken: proposal.context.ownerToken,
          proposedContent: proposal.proposedContent,
          expiresAt: proposal.expiresAt,
          claimToken: token,
          revalidateAuthorization: () async =>
              throw const WorkspaceBoundaryException('permission_changed'),
        ),
        throwsA(isA<WorkspaceBoundaryException>()),
      );
      expect(boundary.prepared, isEmpty);
      await coordinator.abandonClaim(
        proposal.identity,
        token,
        proposal.context.ownerToken,
      );
      expect(journal.records, isEmpty);
    });
  });
}

Future<void> _commitAndAcknowledge(
  WorkspaceMutationCoordinator coordinator,
  PendingWorkspaceProposal proposal,
) async {
  final result = await _claimAndCommit(coordinator, proposal);
  await coordinator.acknowledgeOutcome(result.operationId, result.token);
}

Future<WorkspaceMutationResult> _claimAndCommit(
  WorkspaceMutationCoordinator coordinator,
  PendingWorkspaceProposal proposal,
) async {
  final pending = proposal.status == WorkspaceProposalStatus.pending
      ? proposal
      : proposal.pending();
  final token = await coordinator.beginClaim(
    pending.identity,
    pending.workspaceBindingSnapshot,
    pending.context.ownerToken,
  );
  final executing = pending.executing(token);
  return coordinator.commit(
    identity: executing.identity,
    ownerToken: executing.context.ownerToken,
    proposedContent: executing.proposedContent,
    expiresAt: executing.expiresAt,
    claimToken: token,
    revalidateAuthorization: () async {},
  );
}

PendingWorkspaceProposal _proposal(
  String operation, {
  required String path,
  String? destination,
  String? content,
  WorkspaceEntry? source,
  String root = 'root',
  bool expired = false,
  int call = 0,
}) {
  final now = DateTime.now().toUtc();
  final preview = '$operation $path ${content ?? ''}';
  return PendingWorkspaceProposal(
    conversationId: 'conversation',
    requestId: 'request',
    assistantMessageId: 'assistant',
    toolCallId: 'call-$call',
    callOccurrence: call,
    toolCallIndex: call,
    operation: operation,
    path: path,
    destination: destination,
    proposedContent: content,
    proposedContentHash: content == null
        ? null
        : workspaceHash(utf8.encode(content)),
    patch: operation == 'apply_patch' ? 'exact patch preview' : null,
    preview: preview,
    previewHash: workspaceHash(utf8.encode(preview)),
    sourceIdentity: source?.identity,
    sourceHash: source?.sha256,
    sourceType: source?.type.name,
    targetMissing: true,
    sessionKey: 'session',
    allowedTools: {operation},
    selectedAgentId: 'agent',
    workspaceBindingSnapshot: WorkspaceBindingSnapshot(
      isContentUri: false,
      value: root,
      identity: root == 'root' ? 'root' : 'false:$root',
      rootIdentity: root == 'root' ? 'root' : 'false:$root',
    ),
    createdAt: expired ? now.subtract(const Duration(minutes: 30)) : now,
    expiresAt: expired
        ? now.subtract(const Duration(minutes: 1))
        : now.add(const Duration(minutes: 15)),
  );
}
