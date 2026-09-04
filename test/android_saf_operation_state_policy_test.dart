import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android SAF mutations use redundant checksummed native state', () {
    final source = Directory('android/app/src/main/kotlin/com/rslnmzhn/mobilka')
        .listSync()
        .whereType<File>()
        .where(
          (file) =>
              file.path.contains('SessionWorkspaceSaf') ||
              file.path.contains('SafWorkspace'),
        )
        .map((file) => file.readAsStringSync())
        .join('\n');
    final bridge = File(
      'android/app/src/main/kotlin/com/rslnmzhn/mobilka/'
      'SessionWorkspaceSafBridge.kt',
    ).readAsStringSync();
    final store = File(
      'android/app/src/main/kotlin/com/rslnmzhn/mobilka/'
      'SafOperationStateStore.kt',
    ).readAsStringSync();

    expect(source, contains('"state.a"'));
    expect(source, contains('"state.b"'));
    expect(source, contains('persist(loaded, "createMoving")'));
    expect(source, contains('requireStableMoveIdentity(hidden.uri, id)'));
    expect(source, contains('childByDocumentId'));
    expect(source, contains('"sourceDocId"'));
    expect(source, contains('"stageDocId"'));
    expect(
      source,
      contains('access.childByDocumentId(loaded.hidden, stageIdentity)'),
    );
    expect(source, contains('state.put("movedUri"'));
    expect(source, contains('persist(loaded, "overwriteQuarantined")'));
    expect(source, contains('persist(loaded, "overwriteStageMoved")'));
    expect(source, contains('persist(loaded, "rollbackOldRenamed")'));
    for (final checkpoint in const [
      'overwriteQuarantining',
      'overwriteQuarantined',
      'overwriteQuarantineRenaming',
      'overwriteQuarantineRenamed',
      'overwriteStageMoving',
      'overwriteStageMoved',
      'overwriteStageRenaming',
      'overwriteStageRenamed',
      'rollbackStageMoving',
      'rollbackStageMoved',
      'rollbackOldMoving',
      'rollbackOldMoved',
      'rollbackOldRenaming',
      'rollbackOldRenamed',
      'rollbackDeleteMoving',
      'rollbackDeleteMoved',
    ]) {
      expect(source, contains('"$checkpoint"'));
    }
    expect(source, contains('namedQuarantine != exact.uri'));
    expect(source, contains('val parentOriginal = access.childByDocumentId'));
    expect(
      source,
      contains('access.inspect(quarantined, loaded.scope.tree, true).hash'),
    );
    expect(source, contains('brokerFail("saf_two_phase_unsupported")'));
    expect(
      source,
      isNot(contains('else -> if (hasVerifiedBackup(loaded)) "notCommitted"')),
    );
    expect(source, contains('args["hash"] as? Boolean'));
    expect(source, contains('hashFile = hashFile'));
    expect(
      source,
      contains('access.childByDocumentId(hidden.uri, sourceDocId)'),
    );
    expect(
      source,
      contains(r'renameDocument(access, document.uri, "$id.old")'),
    );
    expect(
      source,
      contains('access.inspect(document.uri, scope.tree, true).hash'),
    );
    expect(source, contains('rollbackMovedDocument'));
    expect(source, contains('state.optionalString("movedUri")'));
    expect(source, contains('"readDocument"'));
    expect(source, contains('openFileDescriptor(uri, "r")'));
    expect(source, isNot(contains('openFileDescriptor(uri, "rw")')));
    expect(source, isNot(contains('Os.ftruncate')));
    expect(source, isNot(contains('overwriteVerified')));
    expect(source, contains('"listDocuments"'));
    expect(source, contains('"too_many_entries"'));
    expect(source, contains('deleteMoving'));
    expect(source, contains('DocumentsContract.isChildDocument'));
    expect(source, isNot(contains(r'$operationId.json')));
    expect(bridge.split('\n').length, lessThanOrEqualTo(500));
    for (final file
        in Directory(
          'android/app/src/main/kotlin/com/rslnmzhn/mobilka',
        ).listSync().whereType<File>().where(
          (file) =>
              file.path.contains('SessionWorkspaceSaf') ||
              file.path.contains('SafWorkspace'),
        )) {
      expect(file.readAsLinesSync().length, lessThanOrEqualTo(500));
    }
    expect(bridge, contains('Executors.newSingleThreadExecutor()'));
    expect(store, contains('maxByOrNull { it.generation }'));
    expect(store, contains('checksum'));
    expect(store, contains('canonical(payload)'));
    expect(store, contains('MessageDigest.getInstance("SHA-256")'));
    expect(store, contains('read(document)'));
  });
}
