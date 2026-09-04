import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/workspace/application/session_workspace_boundary.dart';
import 'package:mobilka/features/workspace/data/saf_session_workspace_boundary.dart';
import 'package:mobilka/features/workspace/domain/session_workspace_path.dart';

import 'support/saf_session_workspace_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('delegates two-phase mutation to native SAF broker', () async {
    final access = FakeWorkspaceSaf()..seedWorkspace();
    const channel = MethodChannel(SafSessionWorkspaceBoundary.channelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'rootIdentity') return 'root-id';
      if (call.method == 'prepareMutation') {
        return {
          'operationId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'token': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        };
      }
      if (call.method == 'reconcilePrepared') return 'committed';
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final boundary = SafSessionWorkspaceBoundary(
      directoryUri: FakeWorkspaceSaf.root,
      access: WorkspaceSafTestAdapter(access),
      synchronizeRoot: <T>(action) => action(),
      sessionKey: 'session',
      revalidateAccess: () async {},
    );

    final receipt = await boundary.prepareMutation(
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      WorkspaceMutationPlan(
        operation: 'write_file',
        path: SessionWorkspacePath.parse('new.txt'),
        destination: null,
        bytes: utf8.encode('new'),
        expectedIdentity: null,
        expectedHash: null,
        expectMissing: true,
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
    expect(calls[1].arguments, containsPair('treeUri', FakeWorkspaceSaf.root));
  });
}
