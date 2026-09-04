import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows session workspace broker is no-follow and handle verified', () {
    final source = Directory('windows/runner')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('session_workspace_'))
        .map((file) => file.readAsStringSync())
        .join('\n');
    expect(source, contains('mobilka/session_workspace'));
    expect(source, contains('FILE_FLAG_OPEN_REPARSE_POINT'));
    expect(source, contains('FILE_FLAG_BACKUP_SEMANTICS'));
    expect(source, contains('GENERIC_READ | GENERIC_WRITE | DELETE'));
    expect(source, contains('GetFinalPathNameByHandleW'));
    expect(source, contains('GetFileInformationByHandle'));
    expect(source, contains(RegExp(r'nNumberOfLinks\s*!=\s*1')));
    expect(source, contains('BCryptOpenAlgorithmProvider'));
    expect(source, contains('CREATE_NEW'));
    expect(source, contains('FlushFileBuffers'));
    expect(source, contains('RenameHandleRelative'));
    expect(source, contains('FileRenameInfo'));
    expect(source, contains('RootDirectory'));
    expect(
      source,
      contains(RegExp(r'FILE_SHARE_READ\s*\|\s*FILE_SHARE_WRITE')),
    );
    final productionSource = Directory('windows/runner')
        .listSync()
        .whereType<File>()
        .where(
          (file) =>
              file.path.contains('session_workspace_') &&
              !file.path.contains('native_test'),
        )
        .map((file) => file.readAsStringSync())
        .join('\n');
    expect(productionSource, isNot(contains('FILE_SHARE_DELETE')));
    expect(source, contains('MOVEFILE_WRITE_THROUGH'));
    expect(source, contains('MOVEFILE_REPLACE_EXISTING'));
    expect(source, contains('ReplaceFileW'));
    expect(source, contains('DeleteTemporary(hidden, temporary)'));
    expect(source, contains('OperationPhase::targetQuarantining'));
    expect(source, contains('OperationPhase::targetQuarantined'));
    expect(source, contains('OperationPhase::stageInstalling'));
    expect(source, contains('OperationPhase::committed'));
    expect(source, contains('SetFileInformationByHandle'));
    expect(source, contains('.mobilka-workspace'));
    expect(source, contains('prepareMutation'));
    expect(source, contains('.state'));
    expect(source, contains('BCryptGenRandom'));
    expect(source, contains('kMaxListEntries'));
    expect(source, isNot(contains('CreateProcess')));
    expect(source, isNot(contains('ShellExecute')));
    expect(source, isNot(contains('system(')));
    expect(
      File('windows/runner/CMakeLists.txt').readAsStringSync(),
      contains('add_test(NAME session_workspace_native_test'),
    );
    expect(source, isNot(contains('session_workspace_mutation.cpp')));
  });
}
