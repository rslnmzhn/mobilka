import 'dart:convert';

import '../../chat/application/chat_tool_runtime.dart';
import '../../chat/domain/chat_message.dart';
import '../../chat/domain/chat_tool.dart';
import '../application/workspace_paths.dart';

/// Per-conversation context note (session.md) inside the session folder.
///
/// The model writes a short summary of decisions/context so a later session —
/// possibly with a different model — can pick up where this one stopped.
class SessionNotesTools implements ChatToolRuntime {
  SessionNotesTools({required this.workspace});

  final WorkspaceStore workspace;

  static const writeSessionNotes = ChatToolDefinition(
    effect: ChatToolEffect.mutating,
    name: 'write_session_notes',
    description:
        'Save a short summary of THIS conversation into session.md inside '
        'the session folder (project directory). Include decisions, current '
        'goal, and next steps so another session or model can continue.',
    parameters: {
      'type': 'object',
      'properties': {
        'content': {
          'type': 'string',
          'description': 'Markdown notes for this session.',
        },
      },
      'required': ['content'],
      'additionalProperties': false,
    },
  );

  static const readSessionNotes = ChatToolDefinition(
    effect: ChatToolEffect.readOnly,
    name: 'read_session_notes',
    description:
        'Read the saved session.md notes for the current conversation.',
    parameters: {'type': 'object', 'properties': {}},
  );

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async => [
    if (allowedTools.contains(writeSessionNotes.name)) writeSessionNotes,
    if (allowedTools.contains(readSessionNotes.name)) readSessionNotes,
  ];

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) {
    if (!allowedTools.contains(call.name)) {
      throw StateError('${call.name} is not allowed for this agent');
    }
    return _execute(call, context);
  }

  Future<String> _execute(
    ChatToolCall call,
    ChatToolExecutionContext? context,
  ) async {
    try {
      final key = context?.sessionKey;
      if (context == null || key == null || key.isEmpty) {
        return jsonEncode({'ok': false, 'error': 'invalid session context'});
      }
      switch (call.name) {
        case 'write_session_notes':
          final content = _args(call)['content']?.toString() ?? '';
          if (content.isEmpty) {
            throw const FormatException('content is required');
          }
          final written = await workspace.writeText(
            workspace.sessionNotes(key),
            content,
          );
          return jsonEncode({
            'ok': written,
            if (!written) 'error': 'session path was rejected',
            'file': 'session.md',
          });
        case 'read_session_notes':
          final text = await workspace.readText(workspace.sessionNotes(key));
          return jsonEncode({
            'ok': text != null,
            if (text == null) 'error': 'session notes file not found',
            'content': text ?? '',
          });
        default:
          throw StateError('Unknown session tool: ${call.name}');
      }
    } on FormatException catch (error) {
      return jsonEncode({'ok': false, 'error': error.message});
    } on StateError catch (error) {
      return jsonEncode({'ok': false, 'error': error.message});
    } on WorkspaceStorageException catch (error) {
      return jsonEncode({'ok': false, 'error': error.message});
    } on Object {
      return jsonEncode({'ok': false, 'error': 'session notes I/O failed'});
    }
  }

  Map<String, Object?> _args(ChatToolCall call) => call.arguments.trim().isEmpty
      ? const <String, Object?>{}
      : jsonDecode(call.arguments) as Map<String, Object?>;
}
