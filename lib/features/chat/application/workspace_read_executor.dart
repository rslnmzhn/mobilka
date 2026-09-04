import 'dart:convert';

import '../../workspace/application/session_workspace_authority.dart';
import '../../workspace/application/workspace_tool_helpers.dart';
import '../../workspace/domain/workspace_models.dart';
import '../domain/chat_message.dart';
import 'chat_tool_runtime.dart';
import 'workspace_tool_arguments.dart';

Future<String> executeWorkspaceRead({
  required ChatToolCall call,
  required SessionWorkspaceAuthority authority,
  required ChatToolExecutionContext? context,
}) async {
  final args = parseWorkspaceArguments(call.arguments);
  switch (call.name) {
    case 'read_session_notes':
      requireWorkspaceKeys(args, required: const {});
    case 'list_files':
      requireWorkspaceKeys(
        args,
        required: const {},
        optional: const {'path', 'recursive'},
      );
    case 'search_files':
      requireWorkspaceKeys(
        args,
        required: const {'query'},
        optional: const {'path', 'case_sensitive'},
      );
    case 'read_file':
      requireWorkspaceKeys(
        args,
        required: const {'path'},
        optional: const {'offset', 'max_bytes'},
      );
  }
  try {
    return switch (call.name) {
      'list_files' => jsonEncode({
        'ok': true,
        'entries': (await authority.listFiles(
          path: optionalWorkspaceString(args, 'path') ?? '',
          recursive: optionalWorkspaceBool(args, 'recursive') ?? false,
        )).map(publicWorkspaceEntry).toList(),
      }),
      'search_files' => jsonEncode({
        'ok': true,
        ...(await authority.searchFiles(
          requiredWorkspaceString(args, 'query'),
          path: optionalWorkspaceString(args, 'path') ?? '',
          caseSensitive: optionalWorkspaceBool(args, 'case_sensitive') ?? false,
          cancelled: () => context?.cancellation?.isCancelled ?? false,
        )).toJson(),
      }),
      'read_file' => jsonEncode(
        (await authority.readFile(
          requiredWorkspaceString(args, 'path'),
          offset: optionalWorkspaceInt(args, 'offset') ?? 0,
          maxBytes:
              optionalWorkspaceInt(args, 'max_bytes') ?? workspaceMaxReadBytes,
        )).toJson(),
      ),
      'read_session_notes' => jsonEncode({
        'ok': true,
        'content': (await authority.readEntireFile('session.md')).content,
      }),
      _ => jsonEncode({'ok': false, 'error_code': 'unknown_tool'}),
    };
  } on Object catch (error) {
    return jsonEncode({'ok': false, 'error_code': workspaceSafeError(error)});
  }
}
