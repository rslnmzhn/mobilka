import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/workspace/application/session_workspace_boundary.dart';
import 'package:mobilka/features/workspace/application/session_workspace_authority.dart';
import 'package:mobilka/features/workspace/application/workspace_mutation_coordinator.dart';
import 'package:mobilka/features/workspace/application/workspace_recovery_record.dart';
import 'package:mobilka/features/workspace/data/workspace_recovery_journal.dart';
import 'package:mobilka/features/workspace/data/native_session_workspace_boundary.dart';
import 'package:mobilka/features/workspace/domain/workspace_operation_identity.dart';
import 'package:mobilka/core/workspace/workspace_binding.dart';
import 'package:mobilka/features/workspace/domain/session_workspace_path.dart';
import 'package:mobilka/features/workspace/domain/workspace_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(NativeSessionWorkspaceBoundary.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('maps native metadata, list, and bounded read results', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'rootIdentity' => '1:1:1',
        'metadata' => {
          'path': 'a.txt',
          'type': 'file',
          'size': 4,
          'identity': '1:2:3',
          'sha256': 'hash',
        },
        'list' => [
          {'path': 'docs', 'type': 'directory', 'size': 0, 'identity': '1:2:4'},
        ],
        'read' => {
          'bytes': Uint8List.fromList(utf8.encode('é')),
          'size': 4,
          'sha256': 'hash',
          'nextOffset': 3,
          'truncated': true,
          'identity': '1:2:3',
        },
        _ => null,
      };
    });
    final boundary = NativeSessionWorkspaceBoundary(
      rootPath: r'C:\workspace',
      sessionKey: 'session',
      revalidateAccess: () async {},
      channel: channel,
    );

    final metadata = await boundary.metadata(
      SessionWorkspacePath.parse('a.txt'),
    );
    final listed = await boundary.list(
      SessionWorkspacePath.parse('', allowRoot: true),
      recursive: true,
    );
    final read = await boundary.read(
      SessionWorkspacePath.parse('a.txt'),
      offset: 1,
      maxBytes: 2,
    );

    expect(metadata?.identity, '1:2:3');
    expect(listed.single.type, WorkspaceEntryType.directory);
    expect(read.content, 'é');
    expect(read.identity, '1:2:3');
    expect(calls[0].arguments, {'root': r'C:\workspace'});
    expect(calls[1].arguments, {
      'root': r'C:\workspace',
      'sessionKey': 'session',
      'path': 'a.txt',
      'rootIdentity': '1:1:1',
    });
    expect(calls[2].arguments, {
      'root': r'C:\workspace',
      'sessionKey': 'session',
      'path': '',
      'recursive': true,
      'rootIdentity': '1:1:1',
    });
    expect(calls[3].arguments, {
      'root': r'C:\workspace',
      'sessionKey': 'session',
      'path': 'a.txt',
      'offset': 1,
      'maxBytes': 2,
      'rootIdentity': '1:1:1',
    });
  });

  test('maps two-phase mutation arguments exactly', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'rootIdentity') return '1:1:1';
      if (call.method == 'prepareMutation') {
        return {
          'operationId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'token': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        };
      }
      if (call.method == 'reconcilePrepared') return 'committed';
      return null;
    });
    final boundary = NativeSessionWorkspaceBoundary(
      rootPath: r'C:\workspace',
      sessionKey: 'session',
      revalidateAccess: () async {},
      channel: channel,
    );
    final receipt = await boundary.prepareMutation(
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      WorkspaceMutationPlan(
        operation: 'write_file',
        path: SessionWorkspacePath.parse('a.txt'),
        destination: null,
        bytes: utf8.encode('new'),
        expectedIdentity: '1:2:3',
        expectedHash: 'old',
        expectMissing: false,
      ),
    );
    await boundary.commitPrepared(receipt);
    expect(
      await boundary.reconcilePrepared(receipt),
      WorkspacePreparedState.committed,
    );
    await boundary.rollbackPrepared(receipt);
    await boundary.cleanupPrepared(receipt);

    expect(calls.map((call) => call.method), [
      'rootIdentity',
      'prepareMutation',
      'commitPrepared',
      'reconcilePrepared',
      'rollbackPrepared',
      'cleanupPrepared',
    ]);
    expect(
      calls[1].arguments,
      containsPair('bytes', Uint8List.fromList(utf8.encode('new'))),
    );
    expect(calls[1].arguments, containsPair('expectMissing', false));
    expect(calls[2].arguments, containsPair('prepared', receipt.toJson()));
  });

  test('maps native failures and rejects malformed native results', () async {
    final boundary = NativeSessionWorkspaceBoundary(
      rootPath: r'C:\workspace',
      sessionKey: 'session',
      revalidateAccess: () async {},
      channel: channel,
    );
    messenger.setMockMethodCallHandler(
      channel,
      (call) => throw PlatformException(code: 'stale_target'),
    );
    await expectLater(
      boundary.metadata(SessionWorkspacePath.parse('a.txt')),
      throwsA(
        isA<WorkspaceBoundaryException>().having(
          (error) => error.code,
          'code',
          'stale_target',
        ),
      ),
    );

    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'rootIdentity') return '1:1:1';
      return {'size': 1};
    });
    await expectLater(
      boundary.metadata(SessionWorkspacePath.parse('a.txt')),
      throwsA(isA<WorkspaceBoundaryException>()),
    );
  });

  test('rejects caller-forgeable prepared receipts', () {
    expect(
      () => PreparedWorkspaceMutation.fromJson({
        'operationId': 'a' * 32,
        'token': 'b' * 43,
        'proof': {'expectedIdentity': 'forged'},
      }),
      throwsA(isA<WorkspaceBoundaryException>()),
    );
    expect(
      () => PreparedWorkspaceMutation.fromJson({
        'operationId': 'a' * 32,
        'token': 'short',
      }),
      throwsA(isA<WorkspaceBoundaryException>()),
    );
  });

  test(
    'preserves opaque receipt across a crash-like channel failure',
    () async {
      var commits = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'rootIdentity') return '1:1:1';
        if (call.method == 'prepareMutation') {
          return {'operationId': 'a' * 32, 'token': 'b' * 43};
        }
        if (call.method == 'commitPrepared' && commits++ == 0) {
          throw PlatformException(code: 'mutation_indeterminate');
        }
        if (call.method == 'reconcilePrepared') return 'committed';
        return null;
      });
      final boundary = NativeSessionWorkspaceBoundary(
        rootPath: r'C:\workspace',
        sessionKey: 'session',
        revalidateAccess: () async {},
        channel: channel,
      );
      final receipt = await boundary.prepareMutation(
        'a' * 32,
        WorkspaceMutationPlan(
          operation: 'write_file',
          path: SessionWorkspacePath.parse('a.txt'),
          destination: null,
          bytes: utf8.encode('new'),
          expectedIdentity: null,
          expectedHash: null,
          expectMissing: true,
        ),
      );
      await expectLater(
        boundary.commitPrepared(receipt),
        throwsA(isA<WorkspaceBoundaryException>()),
      );
      expect(
        await boundary.reconcilePrepared(receipt),
        WorkspacePreparedState.committed,
      );
      expect(receipt.toJson().keys, {'operationId', 'token'});
    },
  );

  test(
    'indeterminate native journal blocks read from an initial binding',
    () async {
      final root = Directory.systemTemp.createTempSync('native-authority-');
      addTearDown(() => root.deleteSync(recursive: true));
      var reads = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'rootIdentity') return 'native-root';
        if (call.method == 'reconcilePrepared') return 'indeterminate';
        if (call.method == 'read') reads++;
        return null;
      });
      final boundary = NativeSessionWorkspaceBoundary(
        rootPath: root.path,
        sessionKey: 'session',
        revalidateAccess: () async {},
        channel: channel,
      );
      final journal = InMemoryWorkspaceRecoveryJournal();
      final operation = WorkspaceOperationIdentity(
        operationId: 'a' * 64,
        sessionKey: 'session',
        rootIdentity: 'native-root',
        operation: 'write_file',
        path: 'a.txt',
        destination: null,
        proposedContentHash: 'b' * 64,
        sourceIdentity: null,
        sourceHash: null,
        sourceType: null,
        targetIdentity: null,
        targetHash: null,
        targetType: null,
        targetMissing: true,
      );
      final bindingSnapshot = const WorkspaceBindingSnapshot(
        isContentUri: false,
        value: 'location',
        identity: 'location-only',
        rootIdentity: 'native-root',
      );
      final record =
          WorkspaceRecoveryRecord.claimed(
            operation,
            bindingSnapshot,
            'c' * 43,
            'owner',
          ).preparedWith(
            PreparedWorkspaceMutation(operationId: 'd' * 32, token: 'e' * 43),
          );
      await journal.put(operation.journalKey, record.toJson());
      final coordinator = WorkspaceMutationCoordinator(
        rootIdentity: await boundary.rootIdentity(),
        sessionKey: 'session',
        boundary: boundary,
        journal: journal,
      );
      final authority = SessionWorkspaceAuthority(
        conversationId: 'conversation',
        requestId: 'request',
        sessionKey: 'session',
        binding: const TestWorkspaceBinding(
          testSnapshot: WorkspaceBindingSnapshot(
            isContentUri: false,
            value: 'location',
            identity: 'location-only',
          ),
        ),
        rootIdentity: 'native-root',
        boundary: boundary,
        recover: coordinator.recoverLocked,
      );

      await expectLater(
        authority.readFile('a.txt'),
        throwsA(isA<WorkspaceRecoveryPendingException>()),
      );
      expect(reads, 0);
    },
  );

  test('native root change fails before recovery or read', () async {
    final root = Directory.systemTemp.createTempSync('native-root-change-');
    addTearDown(() => root.deleteSync(recursive: true));
    var rootIdentity = 'first';
    var reads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'rootIdentity') return rootIdentity;
      if (call.method == 'read') reads++;
      return null;
    });
    final boundary = NativeSessionWorkspaceBoundary(
      rootPath: root.path,
      sessionKey: 'session',
      revalidateAccess: () async {},
      channel: channel,
    );
    await boundary.rootIdentity();
    rootIdentity = 'second';
    var recovered = false;
    final authority = SessionWorkspaceAuthority(
      conversationId: 'conversation',
      requestId: 'request',
      sessionKey: 'session',
      binding: const WorkspaceBinding.fakeForTest(),
      rootIdentity: 'first',
      boundary: boundary,
      recover: (_) async => recovered = true,
    );

    await expectLater(
      authority.readFile('a.txt'),
      throwsA(
        isA<WorkspaceBoundaryException>().having(
          (error) => error.code,
          'code',
          'workspace_binding_changed',
        ),
      ),
    );
    expect(recovered, isFalse);
    expect(reads, 0);
  });
}
