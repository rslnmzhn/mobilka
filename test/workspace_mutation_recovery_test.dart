import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/workspace_paths.dart';
import 'package:mobilka/features/workspace/application/workspace_mutation_coordinator.dart';
import 'package:mobilka/features/workspace/data/workspace_recovery_journal.dart';
import 'package:mobilka/features/chat/domain/pending_workspace_proposal.dart';
import 'package:mobilka/features/workspace/domain/workspace_models.dart';

import 'support/workspace_mutation_boundary_fake.dart';

void main() {
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

  test(
    'finalizes a commit when the call crashes after the exact effect',
    () async {
      boundary.seed('a.txt', 'old');
      boundary.failAfterWrite = true;
      final result = await _claimAndCommit(
        coordinator,
        _proposal(source: boundary.entry('a.txt')),
      );
      expect(result.outcome, WorkspaceMutationOutcome.committed);
      expect(utf8.decode(boundary.files['a.txt']!), 'new');
      await coordinator.acknowledgeOutcome(result.operationId, result.token);
      expect(journal.records, isEmpty);
    },
  );

  test('retains an indeterminate operation-proof record', () async {
    boundary.seed('a.txt', 'old');
    boundary.failAfterWrite = true;
    boundary.indeterminateReconcile = true;
    final result = await _claimAndCommit(
      coordinator,
      _proposal(source: boundary.entry('a.txt')),
    );
    expect(result.outcome, WorkspaceMutationOutcome.indeterminate);
    expect(journal.records, hasLength(1));
  });

  test('terminal proof survives until conversation acknowledgement', () async {
    final proposal = _proposal();
    final result = await _claimAndCommit(coordinator, proposal);
    final executing = proposal.executing(
      journal.records.values.single['claimToken']! as String,
    );
    final recovered = await coordinator.reconcileProposal(
      executing.identity,
      executing.claimToken,
      executing.context.ownerToken,
    );
    expect(recovered?.payload, result.payload);
    await coordinator.acknowledgeOutcome(result.operationId, result.token);
    expect(journal.records, isEmpty);
    expect(boundary.prepared, isEmpty);
  });

  test('quarantines invalid recovery and blocks the namespace', () async {
    final prefix =
        '${base64Url.encode(utf8.encode('root'))}.'
        '${base64Url.encode(utf8.encode('session'))}.';
    await journal.put('$prefix${'a' * 64}', const {
      'version': 1,
      'state': 'pending',
    });
    await expectLater(
      coordinator.recover(),
      throwsA(isA<WorkspaceRecoveryPendingException>()),
    );
    expect(journal.invalidRecords, hasLength(1));
  });

  test('ignores malformed keys outside the exact namespace shape', () async {
    final prefix =
        '${base64Url.encode(utf8.encode('root'))}.'
        '${base64Url.encode(utf8.encode('session'))}.';
    await journal.put('${prefix}not-an-operation', const {'version': 1});
    await coordinator.recover();
    expect(journal.records, hasLength(1));
    expect(journal.invalidRecords, isEmpty);
  });

  test(
    'blocks another commit until terminal outcome is acknowledged',
    () async {
      final first = await _claimAndCommit(coordinator, _proposal());
      final second = _proposal(call: 1).executing();
      await expectLater(
        coordinator.commit(
          identity: second.identity,
          ownerToken: second.context.ownerToken,
          proposedContent: second.proposedContent,
          expiresAt: second.expiresAt,
          claimToken: second.claimToken!,
          revalidateAuthorization: () async {},
        ),
        throwsA(isA<WorkspaceRecoveryPendingException>()),
      );
      await coordinator.acknowledgeOutcome(first.operationId, first.token);
    },
  );
}

Future<WorkspaceMutationResult> _claimAndCommit(
  WorkspaceMutationCoordinator coordinator,
  PendingWorkspaceProposal proposal,
) async {
  final token = await coordinator.beginClaim(
    proposal.identity,
    proposal.workspaceBindingSnapshot,
    proposal.context.ownerToken,
  );
  final executing = proposal.executing(token);
  return coordinator.commit(
    identity: executing.identity,
    ownerToken: executing.context.ownerToken,
    proposedContent: executing.proposedContent,
    expiresAt: executing.expiresAt,
    claimToken: token,
    revalidateAuthorization: () async {},
  );
}

PendingWorkspaceProposal _proposal({WorkspaceEntry? source, int call = 0}) {
  final now = DateTime.now().toUtc();
  const content = 'new';
  const preview = 'write_file a.txt new';
  return PendingWorkspaceProposal(
    conversationId: 'conversation',
    requestId: 'request',
    assistantMessageId: 'assistant',
    toolCallId: 'call-$call',
    callOccurrence: call,
    toolCallIndex: call,
    operation: 'write_file',
    path: call == 0 ? 'a.txt' : 'b.txt',
    proposedContent: content,
    proposedContentHash: workspaceHash(utf8.encode(content)),
    preview: preview,
    previewHash: workspaceHash(utf8.encode(preview)),
    sourceIdentity: source?.identity,
    sourceHash: source?.sha256,
    sourceType: source?.type.name,
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
  );
}
