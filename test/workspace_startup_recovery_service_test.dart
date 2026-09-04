import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/chat/data/conversation_store.dart';
import 'package:mobilka/features/chat/application/chat_workspace_startup_recovery.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/memory/application/workspace_paths.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';
import 'package:mobilka/features/workspace/application/session_workspace_boundary.dart';
import 'package:mobilka/features/workspace/application/workspace_startup_recovery_service.dart';
import 'package:mobilka/features/workspace/data/workspace_recovery_journal.dart';
import 'package:mobilka/features/chat/domain/pending_workspace_proposal.dart';
import 'package:mobilka/features/workspace/domain/workspace_models.dart';
import 'package:saf/saf.dart';

void main() {
  late Directory root;
  late ConversationStore conversations;
  late InMemoryWorkspaceRecoveryJournal journal;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('workspace-startup-test-');
    Hive.init(root.path);
    await Hive.openBox<dynamic>('conversations');
    conversations = ConversationStore();
    journal = InMemoryWorkspaceRecoveryJournal();
  });

  tearDown(() async {
    await Hive.close();
    await root.delete(recursive: true);
  });

  ChatWorkspaceStartupRecovery service(
    SessionWorkspaceBoundary boundary, {
    required Future<WorkspaceBinding> Function(WorkspaceBindingSnapshot)
    restore,
  }) => ChatWorkspaceStartupRecovery(
    conversations: conversations,
    memoryRepository: MemoryRepository(Saf()),
    journal: journal,
    workspaceRecovery: WorkspaceStartupRecoveryService(
      journal: journal,
      restoreBinding: restore,
      boundaryFactory: (_, _) => boundary,
    ),
  );

  test('reconciles exact executing receipt before clearing proposal', () async {
    final proposal = _proposal();
    await conversations.save(_conversation(proposal));
    final receipt = PreparedWorkspaceMutation(
      operationId: 'a' * 32,
      token: 'b' * 43,
    );
    await journal.put(proposal.identity.journalKey, {
      'version': 6,
      'state': 'prepared',
      'operation': proposal.identity.toJson(),
      'ownerToken': proposal.context.ownerToken,
      'claimToken': 'c' * 43,
      'prepared': receipt.toJson(),
      'bindingSnapshot': proposal.workspaceBindingSnapshot.toJson(),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'outcome': null,
      'payload': null,
    });
    final boundary = _RecoveryBoundary(WorkspacePreparedState.committed);
    await service(
      boundary,
      restore: (_) async => const WorkspaceBinding.fakeForTest(),
    ).recover();

    final recovered = conversations.loadById('conversation')!;
    expect(recovered.pendingWorkspaceProposal, isNull);
    expect(recovered.pendingRequestMessageId, isNull);
    expect(recovered.messages.last.toolCallIndex, 0);
    expect(recovered.messages.last.content, contains('committed'));
    expect(boundary.cleaned, isTrue);
    expect(journal.records, isEmpty);
  });

  test(
    'executing proposal without a journal is safely reset to pending',
    () async {
      final proposal = _proposal();
      await conversations.save(_conversation(proposal));
      await service(
        _RecoveryBoundary(WorkspacePreparedState.committed),
        restore: (_) async => throw StateError('unavailable'),
      ).recover();

      final recovered = conversations.loadById('conversation')!;
      expect(
        recovered.pendingWorkspaceProposal?.status,
        WorkspaceProposalStatus.pending,
      );
      expect(recovered.pendingRequestMessageId, 'request');
    },
  );

  test('indeterminate recovery keeps executing proposal and proof', () async {
    final proposal = _proposal();
    await conversations.save(_conversation(proposal));
    final receipt = PreparedWorkspaceMutation(
      operationId: 'a' * 32,
      token: 'b' * 43,
    );
    await journal.put(proposal.identity.journalKey, {
      'version': 6,
      'state': 'prepared',
      'operation': proposal.identity.toJson(),
      'ownerToken': proposal.context.ownerToken,
      'claimToken': 'c' * 43,
      'prepared': receipt.toJson(),
      'bindingSnapshot': proposal.workspaceBindingSnapshot.toJson(),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'outcome': null,
      'payload': null,
    });

    await service(
      _RecoveryBoundary(WorkspacePreparedState.indeterminate),
      restore: (_) async => const WorkspaceBinding.fakeForTest(),
    ).recover();

    expect(
      conversations.loadById('conversation')!.pendingWorkspaceProposal?.status,
      WorkspaceProposalStatus.executing,
    );
    expect(journal.records, hasLength(1));
  });

  test(
    'forward record quarantines and safely terminates matching proposal',
    () async {
      final proposal = _proposal();
      await conversations.save(_conversation(proposal));
      final key = _journalKey();
      await journal.put(
        key,
        _record(proposal, state: 'claimed')..['version'] = 7,
      );

      await service(
        _RecoveryBoundary(WorkspacePreparedState.committed),
        restore: (_) async => const WorkspaceBinding.fakeForTest(),
      ).recover();

      final recovered = conversations.loadById('conversation')!;
      expect(recovered.pendingWorkspaceProposal, isNull);
      expect(recovered.pendingRequestMessageId, isNull);
      expect(
        recovered.messages.last.content,
        contains('workspace_recovery_invalid'),
      );
      expect(journal.records, isEmpty);
      expect(journal.invalidRecords, contains(key));
    },
  );

  test('conversation-agnostic detection leaves invalid proof active', () async {
    final proposal = _proposal();
    final key = _journalKey();
    await journal.put(key, {
      ..._record(proposal, state: 'prepared'),
      'prepared': {'malformed': true},
    });
    final recovery = WorkspaceStartupRecoveryService(
      journal: journal,
      restoreBinding: (_) async => const WorkspaceBinding.fakeForTest(),
      boundaryFactory: (_, _) =>
          _RecoveryBoundary(WorkspacePreparedState.committed),
    );

    final outcomes = await recovery.recover();

    expect(outcomes.single.kind, WorkspaceStartupRecoveryKind.invalid);
    expect(outcomes.single.invalidHandle?.key, key);
    expect(journal.records, contains(key));
    expect(journal.invalidRecords, isEmpty);
  });

  test('mismatched claim quarantines without suppressing proposal', () async {
    final proposal = _proposal();
    await conversations.save(_conversation(proposal));
    final key = _journalKey();
    await journal.put(
      key,
      _record(proposal, state: 'claimed')..['claimToken'] = 'd' * 43,
    );

    await service(
      _RecoveryBoundary(WorkspacePreparedState.committed),
      restore: (_) async => const WorkspaceBinding.fakeForTest(),
    ).recover();

    final recovered = conversations.loadById('conversation')!;
    expect(recovered.pendingWorkspaceProposal, isNotNull);
    expect(recovered.pendingRequestMessageId, 'request');
    expect(journal.invalidRecords, contains(key));
    expect(
      recovered.pendingWorkspaceProposal?.status,
      WorkspaceProposalStatus.pending,
    );
  });

  test(
    'invalid undecodable identity terminalizes canonical-key proposal',
    () async {
      final proposal = _proposal();
      await conversations.save(_conversation(proposal));
      final key = _journalKey();
      await journal.put(key, {
        ..._record(proposal, state: 'claimed'),
        'operation': {'malformed': true},
      });

      await service(
        _RecoveryBoundary(WorkspacePreparedState.committed),
        restore: (_) async => const WorkspaceBinding.fakeForTest(),
      ).recover();

      final recovered = conversations.loadById('conversation')!;
      expect(recovered.pendingWorkspaceProposal, isNull);
      expect(recovered.pendingRequestMessageId, isNull);
      expect(
        recovered.messages.last.content,
        contains('workspace_recovery_invalid'),
      );
      expect(journal.invalidRecords, contains(key));
    },
  );

  test('invalid terminal outcome and payload are quarantined', () async {
    final proposal = _proposal();
    await conversations.save(_conversation(proposal));
    for (final mutation in <void Function(Map<String, Object?>)>[
      (record) => record['outcome'] = 'future',
      (record) => record['payload'] = 'not-a-map',
      (record) => record['prepared'] = null,
    ]) {
      final key = _journalKey();
      final record = _record(proposal, state: 'terminal');
      record['prepared'] = PreparedWorkspaceMutation(
        operationId: 'a' * 32,
        token: 'b' * 43,
      ).toJson();
      record['outcome'] = 'committed';
      record['payload'] = <String, Object?>{'ok': true};
      mutation(record);
      await journal.put(key, record);
      await service(
        _RecoveryBoundary(WorkspacePreparedState.committed),
        restore: (_) async => const WorkspaceBinding.fakeForTest(),
      ).recover();
      expect(journal.invalidRecords, contains(key));
      expect(journal.records, isEmpty);
    }
  });

  test(
    'invalid side-effecting record stays active when terminal save fails',
    () async {
      final proposal = _proposal();
      await conversations.save(_conversation(proposal));
      final key = _journalKey();
      await journal.put(key, {
        ..._record(proposal, state: 'prepared'),
        'prepared': {'malformed': true},
      });
      final failingConversations = _FailingConversationStore();

      await ChatWorkspaceStartupRecovery(
        conversations: failingConversations,
        memoryRepository: MemoryRepository(Saf()),
        journal: journal,
        workspaceRecovery: WorkspaceStartupRecoveryService(
          journal: journal,
          restoreBinding: (_) async => const WorkspaceBinding.fakeForTest(),
          boundaryFactory: (_, _) =>
              _RecoveryBoundary(WorkspacePreparedState.committed),
        ),
      ).recover();

      final recovered = conversations.loadById('conversation')!;
      expect(
        recovered.pendingWorkspaceProposal?.status,
        WorkspaceProposalStatus.executing,
      );
      expect(journal.records, contains(key));
      expect(journal.invalidRecords, isEmpty);
    },
  );

  test(
    'saved invalid terminal is retried only for quarantine acknowledgement',
    () async {
      final proposal = _proposal();
      await conversations.save(_conversation(proposal));
      final key = _journalKey();
      await journal.put(key, {
        ..._record(proposal, state: 'prepared'),
        'prepared': {'malformed': true},
      });
      final failingJournal = _FailingQuarantineJournal(journal);
      final recovery = ChatWorkspaceStartupRecovery(
        conversations: conversations,
        memoryRepository: MemoryRepository(Saf()),
        journal: failingJournal,
        workspaceRecovery: WorkspaceStartupRecoveryService(
          journal: failingJournal,
          restoreBinding: (_) async => const WorkspaceBinding.fakeForTest(),
          boundaryFactory: (_, _) =>
              _RecoveryBoundary(WorkspacePreparedState.committed),
        ),
      );

      await recovery.recover();

      final terminal = conversations.loadById('conversation')!;
      expect(terminal.pendingWorkspaceProposal, isNull);
      expect(terminal.pendingRequestMessageId, isNull);
      expect(terminal.messages.last.content, contains(key));
      expect(journal.records, contains(key));
      expect(failingJournal.quarantineAttempts, 1);

      failingJournal.failQuarantine = false;
      await recovery.recover();

      final retried = conversations.loadById('conversation')!;
      expect(retried.messages, hasLength(2));
      expect(journal.records, isEmpty);
      expect(journal.invalidRecords, contains(key));
      expect(failingJournal.quarantineAttempts, 2);
    },
  );

  test('invalid success saves terminal before quarantine', () async {
    final proposal = _proposal();
    await conversations.save(_conversation(proposal));
    final key = _journalKey();
    await journal.put(key, {
      ..._record(proposal, state: 'prepared'),
      'prepared': {'malformed': true},
    });
    final orderingJournal = _OrderingJournal(journal, conversations);

    await ChatWorkspaceStartupRecovery(
      conversations: conversations,
      memoryRepository: MemoryRepository(Saf()),
      journal: orderingJournal,
      workspaceRecovery: WorkspaceStartupRecoveryService(
        journal: orderingJournal,
        restoreBinding: (_) async => const WorkspaceBinding.fakeForTest(),
        boundaryFactory: (_, _) =>
            _RecoveryBoundary(WorkspacePreparedState.committed),
      ),
    ).recover();

    expect(orderingJournal.sawDurableTerminal, isTrue);
    expect(journal.records, isEmpty);
  });
}

String _journalKey() => _proposal().identity.journalKey;

Map<String, Object?> _record(
  PendingWorkspaceProposal proposal, {
  required String state,
}) => {
  'version': 6,
  'state': state,
  'operation': proposal.identity.toJson(),
  'ownerToken': proposal.context.ownerToken,
  'claimToken': 'c' * 43,
  'prepared': null,
  'bindingSnapshot': proposal.workspaceBindingSnapshot.toJson(),
  'createdAt': DateTime.now().toUtc().toIso8601String(),
  'outcome': null,
  'payload': null,
};

Conversation _conversation(PendingWorkspaceProposal proposal) => Conversation(
  id: 'conversation',
  title: 'title',
  modelId: 'model',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  pendingRequestMessageId: 'request',
  sessionKey: 'session',
  pendingWorkspaceProposal: proposal,
  messages: [
    ChatMessage(
      id: 'assistant',
      role: ChatRole.assistant,
      content: '',
      createdAt: DateTime.utc(2026),
      status: ChatMessageStatus.streaming,
      toolCalls: const [
        ChatToolCall(id: 'call', name: 'write_file', arguments: '{}'),
      ],
    ),
  ],
);

PendingWorkspaceProposal _proposal() {
  final now = DateTime.now().toUtc();
  const content = 'new';
  const preview = 'CREATE a.txt\nnew';
  return PendingWorkspaceProposal(
    conversationId: 'conversation',
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
      value: 'test-root',
      identity: 'false:',
      rootIdentity: 'false:',
    ),
    createdAt: now,
    expiresAt: now.add(const Duration(minutes: 15)),
    status: WorkspaceProposalStatus.executing,
    claimToken: 'c' * 43,
  );
}

final class _RecoveryBoundary implements SessionWorkspaceBoundary {
  _RecoveryBoundary(this.state);

  WorkspacePreparedState state;
  bool cleaned = false;

  @override
  Future<String> rootIdentity() async => 'false:';

  @override
  Future<T> synchronized<T>(Future<T> Function() action) => action();

  @override
  Future<WorkspacePreparedState> reconcilePrepared(
    PreparedWorkspaceMutation prepared,
  ) async => state;

  @override
  Future<void> rollbackPrepared(PreparedWorkspaceMutation prepared) async {
    state = WorkspacePreparedState.rolledBack;
  }

  @override
  Future<void> cleanupPrepared(PreparedWorkspaceMutation prepared) async {
    cleaned = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FailingConversationStore extends ConversationStore {
  @override
  Future<void> save(Conversation conversation) async {
    throw StateError('injected_save_failure');
  }
}

class _DelegatingJournal implements WorkspaceRecoveryJournal {
  _DelegatingJournal(this.delegate);

  final InMemoryWorkspaceRecoveryJournal delegate;

  @override
  Map<String, Object?> activeSnapshot() => delegate.activeSnapshot();

  @override
  Future<void> put(String key, Map<String, Object?> record) =>
      delegate.put(key, record);

  @override
  Future<void> remove(String key) => delegate.remove(key);

  @override
  Map<String, Object?> snapshot() => delegate.snapshot();

  @override
  Future<void> quarantine(
    String key,
    Object? record,
    String reason, {
    Object? expectedActiveRecord,
  }) => delegate.quarantine(
    key,
    record,
    reason,
    expectedActiveRecord: expectedActiveRecord,
  );
}

final class _FailingQuarantineJournal extends _DelegatingJournal {
  _FailingQuarantineJournal(super.delegate);

  bool failQuarantine = true;
  int quarantineAttempts = 0;

  @override
  Future<void> quarantine(
    String key,
    Object? record,
    String reason, {
    Object? expectedActiveRecord,
  }) async {
    quarantineAttempts++;
    if (failQuarantine) throw StateError('injected_quarantine_failure');
    await super.quarantine(
      key,
      record,
      reason,
      expectedActiveRecord: expectedActiveRecord,
    );
  }
}

final class _OrderingJournal extends _DelegatingJournal {
  _OrderingJournal(super.delegate, this.conversations);

  final ConversationStore conversations;
  bool sawDurableTerminal = false;

  @override
  Future<void> quarantine(
    String key,
    Object? record,
    String reason, {
    Object? expectedActiveRecord,
  }) async {
    final conversation = conversations.loadById('conversation')!;
    sawDurableTerminal =
        conversation.pendingWorkspaceProposal == null &&
        conversation.messages.last.content.contains(
          'workspace_recovery_invalid',
        );
    await super.quarantine(
      key,
      record,
      reason,
      expectedActiveRecord: expectedActiveRecord,
    );
  }
}
