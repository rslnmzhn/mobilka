import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/application/chat_tool_runtime.dart';
import '../../chat/domain/chat_message.dart';
import '../../chat/domain/chat_tool.dart';
import 'persona_registry.dart';

/// Lets the model switch personality overlays by natural request and create
/// or rewrite personas on demand. save_persona/delete_persona go through the
/// standard confirmation flow: the model prepares a proposal for
/// personas.yaml, the owner reviews the diff in the memory dialog. The
/// coordinator intercepts these calls before executeTool and routes them
/// through the standard proposal flow.
class PersonaChatTools implements ChatToolRuntime {
  PersonaChatTools({required this.registry});

  final PersonaRegistryAdapter registry;

  static const listPersonas = ChatToolDefinition(
    effect: ChatToolEffect.readOnly,
    name: 'list_personas',
    description:
        'List available personality overlays (personas.yaml). Use when the '
        'user asks which personas exist.',
    parameters: {'type': 'object', 'properties': {}},
  );

  static const switchPersona = ChatToolDefinition(
    effect: ChatToolEffect.mutating,
    name: 'switch_persona',
    description:
        'Activate a persona overlay for this session (applied on top of '
        'soul.md), or clear the overlay with name "none". Use when the user '
        'asks to become/enable a persona or to turn it off.',
    parameters: {
      'type': 'object',
      'properties': {
        'name': {
          'type': ['string', 'null'],
          'description':
              'Persona name from list_personas, or null/none to reset.',
        },
      },
      'required': [],
      'additionalProperties': false,
    },
  );

  static const savePersona = ChatToolDefinition(
    effect: ChatToolEffect.runtimeConfirmed,
    name: 'save_persona',
    description:
        'Create or update a named personality overlay in personas.yaml. The '
        'user must confirm the exact diff before it is written.',
    parameters: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
        'text': {
          'type': 'string',
          'description': 'Full overlay instructions for this persona.',
        },
      },
      'required': ['name', 'text'],
      'additionalProperties': false,
    },
  );

  static const deletePersona = ChatToolDefinition(
    effect: ChatToolEffect.runtimeConfirmed,
    name: 'delete_persona',
    description:
        'Remove a named persona from personas.yaml. Requires user '
        'confirmation of the diff.',
    parameters: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
      },
      'required': ['name'],
      'additionalProperties': false,
    },
  );

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async => [
    if (allowedTools.contains(listPersonas.name)) listPersonas,
    if (allowedTools.contains(switchPersona.name)) switchPersona,
    if (allowedTools.contains(savePersona.name)) savePersona,
    if (allowedTools.contains(deletePersona.name)) deletePersona,
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
        case 'list_personas':
          final entries = await registry.refresh();
          return jsonEncode({
            'ok': true,
            'active': registry.activeName,
            'personas': [for (final e in entries) e.name],
          });
        case 'switch_persona':
          final name = args['name']?.toString();
          final status = await registry.switchTo(name);
          return jsonEncode({'ok': true, 'status': status});
        default:
          // save_persona/delete_persona are intercepted by the coordinator
          // before executeTool; reaching here means a routing bug.
          throw StateError('Unhandled persona tool: ${call.name}');
      }
    } on FormatException catch (error) {
      return jsonEncode({'ok': false, 'error': error.message});
    }
  }
}

final personaChatToolsProvider = Provider<PersonaChatTools>(
  (ref) =>
      PersonaChatTools(registry: ref.watch(personaRegistryAdapterProvider)),
);
