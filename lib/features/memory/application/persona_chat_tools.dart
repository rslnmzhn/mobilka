import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/application/chat_tool_runtime.dart';
import '../../chat/domain/chat_message.dart';
import '../../chat/domain/chat_tool.dart';
import 'persona_registry.dart';

/// Lets the model switch personality overlays by natural request:
/// "включи персону reviewer", "какие есть персоны?", "выключи персону".
/// The active overlay persists until switched again or cleared.
class PersonaChatTools implements ChatToolRuntime {
  PersonaChatTools({required this.registry});

  final PersonaRegistryAdapter registry;

  static const listPersonas = ChatToolDefinition(
    name: 'list_personas',
    description:
        'List available personality overlays (personas.yaml). Use when the '
        'user asks which personas exist.',
    parameters: {'type': 'object', 'properties': {}},
  );

  static const switchPersona = ChatToolDefinition(
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

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async => [
    if (allowedTools.contains(listPersonas.name)) listPersonas,
    if (allowedTools.contains(switchPersona.name)) switchPersona,
  ];

  @override
  Future<String> executeTool(ChatToolCall call, Set<String> allowedTools) {
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
          throw StateError('Unknown persona tool: ${call.name}');
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
