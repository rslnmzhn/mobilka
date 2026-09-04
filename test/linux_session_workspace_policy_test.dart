import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Linux session workspace broker is fd-relative and fail closed', () {
    final source = Directory('linux/runner')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('session_workspace_'))
        .map((file) => file.readAsStringSync())
        .join('\n');
    final application = File(
      'linux/runner/my_application.cc',
    ).readAsStringSync();
    final cmake = File('linux/runner/CMakeLists.txt').readAsStringSync();

    expect(source, contains('mobilka/session_workspace'));
    expect(
      source,
      contains(RegExp(r'O_PATH\s*\|\s*O_DIRECTORY\s*\|\s*O_NOFOLLOW')),
    );
    expect(source, contains('RESOLVE_BENEATH'));
    expect(source, contains('RESOLVE_NO_MAGICLINKS'));
    expect(source, contains('RESOLVE_NO_SYMLINKS'));
    expect(source, contains('RESOLVE_NO_XDEV'));
    expect(source, isNot(contains('return openat(p,n')));
    expect(source, contains('fstatat('));
    expect(source, contains('AT_SYMLINK_NOFOLLOW'));
    expect(source, contains('F_DUPFD_CLOEXEC'));
    expect(source, contains('fdopendir('));
    expect(source, contains(RegExp(r'st_nlink\s*!=\s*1')));
    expect(source, contains('g_checksum_new(G_CHECKSUM_SHA256)'));
    expect(source, contains('RENAME_NOREPLACE'));
    expect(source, contains('RENAME_EXCHANGE'));
    expect(source, contains('.mobilka-workspace'));
    expect(source, contains('prepareMutation'));
    expect(source, contains('fsync('));
    expect(source, contains('getrandom('));
    expect(source, contains('O_EXCL'));
    expect(source, contains('OperationPhase::stageInstalling'));
    expect(source, contains('OperationPhase::targetQuarantining'));
    expect(source, contains('SaveOperationState'));
    expect(source, contains('LoadOperationState'));
    expect(source, contains('DeleteOperationState'));
    expect(source, contains('id + ".state"'));
    expect(source, contains(RegExp(r'fl_value_get_length\(r\)\s*!=\s*2')));
    expect(source, isNot(contains('"proof"')));
    expect(source, contains('kMaxListEntries'));
    expect(source, contains(RegExp(r'names\.size\(\)\s*==\s*kMaxListEntries')));
    expect(source, contains(RegExp(r'listed\.st_dev\s*!=\s*d\.id\.device')));
    expect(source, contains('"too_many_entries"'));
    expect(source, contains(RegExp(r'out->size\(\)\s*>\s*16')));
    expect(source, isNot(contains('system(')));
    expect(source, isNot(contains('CreateProcess')));
    expect(application, contains('register_session_workspace_channel'));
    expect(cmake, contains('session_workspace_common.cc'));
    expect(cmake, contains('session_workspace_state.cc'));
    expect(cmake, contains('session_workspace_prepare_commit.cc'));
    expect(cmake, contains('session_workspace_recovery.cc'));
    expect(cmake, contains('session_workspace_native_test.cc'));
  });
}
