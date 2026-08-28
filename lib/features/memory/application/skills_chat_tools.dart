import 'dart:convert';

import '../../chat/application/chat_tool_runtime.dart';
import '../../chat/domain/chat_message.dart';
import '../../chat/domain/chat_tool.dart';
import 'workspace_paths.dart';

/// Self-authored skill files under the storage-root skills folder.
///
/// The agent writes skills for itself to adapt to this environment and reads
/// them back instead of re-exploring the codebase. No internet search is
/// involved; fetching external sources is a separate capability.
class SkillsChatTools implements ChatToolRuntime {
  SkillsChatTools({required this.workspace, this.maxSkillBytes = 262144});

  final WorkspaceStore workspace;
  final int maxSkillBytes;

  static const writeSkill = ChatToolDefinition(
    effect: ChatToolEffect.mutating,
    name: 'write_skill',
    description:
        'Create or overwrite a reusable skill note at skills/NAME.md. '
        'Use it to capture environment-specific knowledge: how tools behave '
        'here, project conventions, step-by-step recipes that worked. Write '
        'skills proactively when you learn something worth reusing.',
    parameters: {
      'type': 'object',
      'properties': {
        'name': {
          'type': 'string',
          'description':
              'Short kebab-case identifier, e.g. "mobilka-memory-schema".',
        },
        'content': {'type': 'string'},
      },
      'required': ['name', 'content'],
      'additionalProperties': false,
    },
  );

  static const readSkill = ChatToolDefinition(
    effect: ChatToolEffect.readOnly,
    name: 'read_skill',
    description: 'Read the full content of one of your saved skills by name.',
    parameters: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
      },
      'required': ['name'],
      'additionalProperties': false,
    },
  );

  static const listSkills = ChatToolDefinition(
    effect: ChatToolEffect.readOnly,
    name: 'list_skills',
    description: 'List names of all saved skills.',
    parameters: {'type': 'object', 'properties': {}},
  );

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async => [
    if (allowedTools.contains(writeSkill.name)) writeSkill,
    if (allowedTools.contains(readSkill.name)) readSkill,
    if (allowedTools.contains(listSkills.name)) listSkills,
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
    return _execute(call);
  }

  Future<String> _execute(ChatToolCall call) async {
    try {
      final args = call.arguments.trim().isEmpty
          ? const <String, Object?>{}
          : jsonDecode(call.arguments) as Map;
      switch (call.name) {
        case 'write_skill':
          final name = _skillName(args['name']?.toString() ?? '');
          if (name == null) {
            throw const FormatException(
              'Invalid skill name: use kebab-case letters/digits/dashes',
            );
          }
          final content = args['content']?.toString() ?? '';
          final bytes = utf8.encode(content);
          if (bytes.length > maxSkillBytes) {
            throw FormatException(
              'Skill exceeds the ${maxSkillBytes ~/ 1024} KB limit',
            );
          }
          final written = await workspace.writeText(
            workspace.skillFile(name),
            content,
          );
          return jsonEncode({'ok': written, 'file': 'skills/$name.md'});
        case 'read_skill':
          final name = _skillName(args['name']?.toString() ?? '');
          if (name == null) throw const FormatException('Invalid skill name');
          final text = await workspace.readText(workspace.skillFile(name));
          if (text == null) {
            return jsonEncode({'ok': false, 'error': 'skill not found'});
          }
          return jsonEncode({'ok': true, 'name': name, 'content': text});
        case 'list_skills':
          final names = await workspace.listTextFiles(skillsFolder);
          return jsonEncode({'ok': true, 'skills': names});
        default:
          throw StateError('Unknown skill tool: ${call.name}');
      }
    } on FormatException catch (error) {
      return jsonEncode({'ok': false, 'error': error.message});
    }
  }

  static final _skillNamePattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$');

  String? _skillName(String raw) {
    final name = raw.trim();
    return _skillNamePattern.hasMatch(name) ? name : null;
  }
}
