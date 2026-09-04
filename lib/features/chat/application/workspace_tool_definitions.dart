import '../domain/chat_tool.dart';

const workspaceToolDefinitions = <ChatToolDefinition>[
  ChatToolDefinition(
    name: 'read_session_notes',
    effect: ChatToolEffect.readOnly,
    description: 'Read session.md through the bound session workspace.',
    parameters: {
      'type': 'object',
      'properties': <String, Object?>{},
      'additionalProperties': false,
    },
  ),
  ChatToolDefinition(
    name: 'write_session_notes',
    effect: ChatToolEffect.runtimeConfirmed,
    description: 'Propose replacing session.md with conversation notes.',
    parameters: {
      'type': 'object',
      'properties': {
        'content': {'type': 'string'},
      },
      'required': ['content'],
      'additionalProperties': false,
    },
  ),
  ChatToolDefinition(
    name: 'list_files',
    effect: ChatToolEffect.readOnly,
    description: 'List safe files and directories in this session workspace.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'recursive': {'type': 'boolean'},
      },
      'additionalProperties': false,
    },
  ),
  ChatToolDefinition(
    name: 'search_files',
    effect: ChatToolEffect.readOnly,
    description: 'Search literal text in UTF-8 session workspace files.',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
        'path': {'type': 'string'},
        'case_sensitive': {'type': 'boolean'},
      },
      'required': ['query'],
      'additionalProperties': false,
    },
  ),
  ChatToolDefinition(
    name: 'read_file',
    effect: ChatToolEffect.readOnly,
    description: 'Read a bounded UTF-8 chunk from a session workspace file.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'offset': {'type': 'integer'},
        'max_bytes': {'type': 'integer'},
      },
      'required': ['path'],
      'additionalProperties': false,
    },
  ),
  ChatToolDefinition(
    name: 'write_file',
    effect: ChatToolEffect.runtimeConfirmed,
    description: 'Propose creating or replacing one UTF-8 workspace file.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'content': {'type': 'string'},
      },
      'required': ['path', 'content'],
      'additionalProperties': false,
    },
  ),
  ChatToolDefinition(
    name: 'apply_patch',
    effect: ChatToolEffect.runtimeConfirmed,
    description: 'Propose one exact unified patch for one workspace file.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'patch': {'type': 'string'},
      },
      'required': ['path', 'patch'],
      'additionalProperties': false,
    },
  ),
  ChatToolDefinition(
    name: 'move_file',
    effect: ChatToolEffect.runtimeConfirmed,
    description: 'Propose moving one regular file without overwrite.',
    parameters: {
      'type': 'object',
      'properties': {
        'source': {'type': 'string'},
        'destination': {'type': 'string'},
      },
      'required': ['source', 'destination'],
      'additionalProperties': false,
    },
  ),
  ChatToolDefinition(
    name: 'delete_file',
    effect: ChatToolEffect.runtimeConfirmed,
    description: 'Propose deleting one regular session workspace file.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
      },
      'required': ['path'],
      'additionalProperties': false,
    },
  ),
  ChatToolDefinition(
    name: 'make_directory',
    effect: ChatToolEffect.runtimeConfirmed,
    description: 'Propose creating a directory under an existing parent.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
      },
      'required': ['path'],
      'additionalProperties': false,
    },
  ),
];
