import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/workspace_chat_tool_adapter.dart';

void main() {
  test('workspace schemas never expose root, URI or session authority', () {
    expect(
      WorkspaceChatToolRuntime.definitions.map((item) => item.name).toSet(),
      {
        'read_session_notes',
        'write_session_notes',
        'list_files',
        'search_files',
        'read_file',
        'write_file',
        'apply_patch',
        'move_file',
        'delete_file',
        'make_directory',
      },
    );
    for (final definition in WorkspaceChatToolRuntime.definitions) {
      final text = definition.parameters.toString().toLowerCase();
      expect(text, isNot(contains('root')));
      expect(text, isNot(contains('uri')));
      expect(text, isNot(contains('session')));
    }
  });

  test('workspace list output model omits boundary identity', () {
    const definitionNames = {
      'read_session_notes',
      'write_session_notes',
      'list_files',
      'search_files',
      'read_file',
      'write_file',
      'apply_patch',
      'move_file',
      'delete_file',
      'make_directory',
    };
    expect(
      WorkspaceChatToolRuntime.definitions.map((item) => item.name).toSet(),
      definitionNames,
    );
  });
}
