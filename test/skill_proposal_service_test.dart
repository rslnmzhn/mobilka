import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/skill_proposal_service.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/chat/domain/pending_skill_proposal.dart';
import 'package:mobilka/features/memory/application/workspace_paths.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';
import 'package:saf/saf.dart';

const _old = '''# Trigger
old
# Procedure
old
# Validate
old
# Fallbacks
old
# Safety
old''';
const _new = '''# Trigger
new
# Procedure
new
# Validate
new
# Fallbacks
new
# Safety
new''';

void main() {
  late Directory root;
  late _Repository repository;
  late WorkspaceStore workspace;
  late WorkspaceBinding binding;
  late Conversation latest;
  late SkillProposalService service;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('skill-proposal-service-');
    repository = _Repository(
      MemoryLocation(value: root.path, isContentUri: false),
      PathMemoryFileStore(root.path),
    );
    workspace = WorkspaceStore(repository: repository);
    binding = workspace.captureBinding()!;
    service = SkillProposalService(
      persistMutation: (id, mutate) async {
        final changed = mutate(latest);
        if (changed != null) latest = changed;
        return changed;
      },
    );
    addTearDown(() => root.delete(recursive: true));
  });

  test(
    'create remains absent until confirm then writes exact and clears',
    () async {
      final proposal = _proposal(binding: binding, content: _new);
      latest = _conversation(proposal);
      expect(await workspace.readText('skills/safe.md'), isNull);
      expect(await _confirm(service, latest, proposal, binding), isTrue);
      expect(await workspace.readText('skills/safe.md'), _new);
      expect(latest.pendingSkillProposal, isNull);
      expect(latest.messages.last.content, 'skill_saved');
    },
  );

  test(
    'update verifies exact hash and stale manual edit is not overwritten',
    () async {
      await workspace.writeText('skills/safe.md', _old);
      final proposal = _proposal(
        binding: binding,
        old: _old,
        content: _new,
        expectedHash: _hash(_old),
      );
      latest = _conversation(proposal);
      expect(await _confirm(service, latest, proposal, binding), isTrue);
      expect(await workspace.readText('skills/safe.md'), _new);

      await workspace.writeText('skills/safe.md', _old);
      final stale = _proposal(
        binding: binding,
        old: _old,
        content: _new,
        expectedHash: _hash(_old),
        requestId: 'stale',
      );
      latest = _conversation(stale);
      await workspace.writeText('skills/safe.md', 'manual edit');
      expect(await _confirm(service, latest, stale, binding), isFalse);
      expect(await workspace.readText('skills/safe.md'), 'manual edit');
      expect(latest.pendingSkillProposal, isNull);
    },
  );

  test('reject clears proposal without writing', () async {
    final proposal = _proposal(binding: binding, content: _new);
    latest = _conversation(proposal);
    expect(await service.reject(latest, proposal), isTrue);
    expect(latest.pendingSkillProposal, isNull);
    expect(await workspace.readText('skills/safe.md'), isNull);
  });

  test('concurrent confirmation claims and commits exactly once', () async {
    final proposal = _proposal(binding: binding, content: _new);
    latest = _conversation(proposal);
    final original = latest;
    final results = await Future.wait([
      _confirm(service, original, proposal, binding),
      _confirm(service, original, proposal, binding),
    ]);
    expect(results.where((value) => value), hasLength(1));
    expect(await workspace.readText('skills/safe.md'), _new);
    expect(
      latest.messages.where((m) => m.content == 'skill_saved'),
      hasLength(1),
    );
  });

  test(
    'changed permission, agent, or allowlist rejects before write',
    () async {
      for (final scenario in ['permission', 'agent', 'allowlist']) {
        final proposal = _proposal(
          binding: binding,
          content: _new,
          requestId: scenario,
        );
        latest = _conversation(proposal);
        await expectLater(
          service.confirm(
            conversation: latest,
            proposal: proposal,
            selectedAgentId: scenario == 'agent' ? 'other' : 'agent',
            allowedTools: scenario == 'allowlist'
                ? const <String>{}
                : const {'propose_skill'},
            workspaceSnapshot: scenario == 'permission'
                ? 'changed'
                : binding.permissionSnapshot,
            workspaceBinding: binding,
          ),
          throwsStateError,
        );
        expect(await workspace.readText('skills/safe.md'), isNull);
      }
    },
  );

  test(
    'restoring proposal against changed current location fails closed',
    () async {
      final snapshot = binding.snapshot;
      repository.location = MemoryLocation(
        value: '${root.path}-changed',
        isContentUri: false,
      );
      await expectLater(workspace.restoreBinding(snapshot), throwsStateError);
    },
  );

  test('path quota and concurrent creates cannot exceed limits', () async {
    final store = PathMemoryFileStore(root.path);
    expect(
      await store.commitSkillCandidate(
        name: 'first.md',
        content: '1234',
        expectedHash: null,
        maxCount: 1,
        maxTotalBytes: 4,
      ),
      SkillCommitResult.written,
    );
    expect(
      await store.commitSkillCandidate(
        name: 'second.md',
        content: '1',
        expectedHash: null,
        maxCount: 1,
        maxTotalBytes: 4,
      ),
      SkillCommitResult.quotaExceeded,
    );
    final otherRoot = await Directory.systemTemp.createTemp(
      'skill-quota-race-',
    );
    addTearDown(() => otherRoot.delete(recursive: true));
    final first = PathMemoryFileStore(otherRoot.path);
    final second = PathMemoryFileStore(otherRoot.path);
    final outcomes = await Future.wait([
      first.commitSkillCandidate(
        name: 'a.md',
        content: '123',
        expectedHash: null,
        maxCount: 1,
        maxTotalBytes: 3,
      ),
      second.commitSkillCandidate(
        name: 'b.md',
        content: '123',
        expectedHash: null,
        maxCount: 1,
        maxTotalBytes: 3,
      ),
    ]);
    expect(
      outcomes.where((value) => value == SkillCommitResult.written),
      hasLength(1),
    );
    expect(
      outcomes.where((value) => value == SkillCommitResult.quotaExceeded),
      hasLength(1),
    );
  });
}

Future<bool> _confirm(
  SkillProposalService service,
  Conversation conversation,
  PendingSkillProposal proposal,
  WorkspaceBinding binding,
) => service.confirm(
  conversation: conversation,
  proposal: proposal,
  selectedAgentId: 'agent',
  allowedTools: const {'propose_skill'},
  workspaceSnapshot: binding.permissionSnapshot,
  workspaceBinding: binding,
);

PendingSkillProposal _proposal({
  required WorkspaceBinding binding,
  required String content,
  String? old,
  String? expectedHash,
  String requestId = 'request',
}) => PendingSkillProposal(
  conversationId: 'conversation',
  requestId: requestId,
  assistantMessageId: 'assistant',
  name: 'safe',
  oldContent: old,
  proposedContent: content,
  expectedHash: expectedHash,
  sourceDerived: false,
  provenanceSummary: 'trusted_local',
  warnings: const [],
  permissionSnapshot: binding.permissionSnapshot,
  workspaceBindingSnapshot: binding.snapshot,
  selectedAgentId: 'agent',
  createdAt: DateTime.now().toUtc(),
);

Conversation _conversation(PendingSkillProposal proposal) => Conversation(
  id: 'conversation',
  title: 'title',
  modelId: 'model',
  createdAt: DateTime.now(),
  updatedAt: DateTime.now(),
  messages: const [],
  pendingRequestMessageId: proposal.requestId,
  pendingSkillProposal: proposal,
);

String _hash(String content) => sha256.convert(utf8.encode(content)).toString();

class _Repository extends MemoryRepository {
  _Repository(this.location, this.boundary) : super(Saf());
  MemoryLocation location;
  final MemoryFileBoundary boundary;

  @override
  MemoryLocation? savedLocation() => location;

  @override
  MemoryFileBoundary boundaryFor(MemoryLocation location) => boundary;

  @override
  Future<void> validateSavedLocationAccess(MemoryLocation location) async {}
}
