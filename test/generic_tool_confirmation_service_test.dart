import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/automatic_title_coordinator.dart';
import 'package:mobilka/features/chat/application/generic_tool_confirmation_service.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/chat/domain/pending_tool_proposal.dart';

void main() {
  test('stale identity dimensions and authorization changes reject', () async {
    final base = _proposal();
    for (final bad in [
      _proposal(conversationId: 'wrong'),
      _proposal(requestId: 'wrong'),
      _proposal(assistantMessageId: 'wrong'),
      _proposal(callOccurrence: 1),
    ]) {
      final fixture = _Fixture(base);
      await expectLater(fixture.confirm(bad), throwsStateError);
      expect(fixture.executions, 0);
    }
    final fixture = _Fixture(base);
    await expectLater(
      fixture.confirm(base, selectedAgentId: 'changed'),
      throwsStateError,
    );
    await expectLater(
      fixture.confirm(base, allowed: const {}),
      throwsStateError,
    );
    await expectLater(
      fixture.confirm(base, effect: ChatToolEffect.sensitive),
      throwsStateError,
    );
    await expectLater(
      fixture.confirm(base, workspace: 'changed'),
      throwsStateError,
    );
  });

  test('reject never executes and persists safe result', () async {
    final proposal = _proposal();
    final fixture = _Fixture(proposal);
    expect(
      await fixture.service.reject(
        conversation: fixture.conversation,
        proposal: proposal,
      ),
      isTrue,
    );
    expect(fixture.executions, 0);
    expect(fixture.conversation.pendingToolProposal, isNull);
    expect(
      fixture.conversation.messages.last.content,
      contains('user_rejected'),
    );
  });

  test('concurrent double confirm executes exact call once', () async {
    final proposal = _proposal();
    final fixture = _Fixture(proposal);
    final gate = Completer<void>();
    final first = fixture.confirm(proposal, gate: gate.future);
    final second = fixture.confirm(proposal);
    gate.complete();
    final results = await Future.wait([first, second]);
    expect(results.where((value) => value).length, 1);
    expect(fixture.executions, 1);
  });

  test(
    'execution failure consumes claim and records safe non-retryable result',
    () async {
      final proposal = _proposal();
      final fixture = _Fixture(proposal);
      expect(await fixture.confirm(proposal, fail: true), isTrue);
      expect(fixture.executions, 1);
      expect(
        fixture.conversation.messages.last.content,
        contains('tool_execution_failed'),
      );
      await expectLater(fixture.confirm(proposal), throwsStateError);
      expect(fixture.executions, 1);
    },
  );

  test(
    'tainted memory.md confirms once and terminally finalizes request',
    () async {
      final proposal = _memoryProposal();
      final fixture = _Fixture(proposal);
      expect(
        await fixture.confirm(
          proposal,
          allowed: const {'update_memory_file'},
          effect: ChatToolEffect.runtimeConfirmed,
        ),
        isTrue,
      );
      expect(fixture.executions, 1);
      expect(fixture.conversation.pendingToolProposal, isNull);
      expect(fixture.conversation.pendingRequestMessageId, isNull);
      await expectLater(
        fixture.confirm(
          proposal,
          allowed: const {'update_memory_file'},
          effect: ChatToolEffect.runtimeConfirmed,
        ),
        throwsStateError,
      );
      expect(fixture.executions, 1);
    },
  );

  test(
    'tainted memory.md permission change rejects before execution',
    () async {
      final proposal = _memoryProposal();
      final fixture = _Fixture(proposal);
      await expectLater(
        fixture.confirm(
          proposal,
          allowed: const {},
          effect: ChatToolEffect.runtimeConfirmed,
        ),
        throwsStateError,
      );
      expect(fixture.executions, 0);
    },
  );
}

PendingToolProposal _memoryProposal() => PendingToolProposal(
  conversationId: 'c',
  requestId: 'r',
  assistantMessageId: 'a',
  callOccurrence: 0,
  call: const ChatToolCall(
    id: 'memory-call',
    name: 'update_memory_file',
    arguments: '{"file_name":"memory.md","content":"x"}',
  ),
  selectedAgentId: 'agent',
  allowedTools: const {'update_memory_file'},
  effect: ChatToolEffect.mutating,
  sourceTainted: true,
  permissionSnapshot: 'workspace',
  createdAt: DateTime(2026),
);

PendingToolProposal _proposal({
  String conversationId = 'c',
  String requestId = 'r',
  String assistantMessageId = 'a',
  int callOccurrence = 0,
}) => PendingToolProposal(
  conversationId: conversationId,
  requestId: requestId,
  assistantMessageId: assistantMessageId,
  callOccurrence: callOccurrence,
  call: const ChatToolCall(
    id: 'call',
    name: 'write_skill',
    arguments: '{"x":1}',
  ),
  selectedAgentId: 'agent',
  allowedTools: const {'write_skill'},
  effect: ChatToolEffect.mutating,
  sourceTainted: true,
  permissionSnapshot: 'workspace',
  createdAt: DateTime(2026),
);

class _Fixture {
  _Fixture(PendingToolProposal proposal)
    : conversation = Conversation(
        id: 'c',
        title: 't',
        modelId: 'm',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        pendingRequestMessageId: 'r',
        pendingToolProposal: proposal,
        messages: const [],
      ) {
    final coordinator = AutomaticTitleCoordinator(
      conversationById: (_) => conversation,
      persist: (value) async => conversation = value,
    );
    service = GenericToolConfirmationService(
      persistMutation: coordinator.mutate,
    );
  }
  late Conversation conversation;
  late final GenericToolConfirmationService service;
  int executions = 0;

  Future<bool> confirm(
    PendingToolProposal proposal, {
    String? selectedAgentId = 'agent',
    Set<String> allowed = const {'write_skill'},
    ChatToolEffect effect = ChatToolEffect.mutating,
    String? workspace = 'workspace',
    Future<void>? gate,
    bool fail = false,
  }) => service.confirm(
    conversation: conversation,
    proposal: proposal,
    selectedAgentId: selectedAgentId,
    currentAllowedTools: allowed,
    definition: ChatToolDefinition(
      name: proposal.call.name,
      description: '',
      parameters: const {},
      effect: effect,
    ),
    workspaceSnapshot: workspace,
    execute: () async {
      executions++;
      if (gate != null) await gate;
      if (fail) throw StateError('secret');
      return '{"ok":true}';
    },
  );
}
