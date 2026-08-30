import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/application/chat_tool_runtime.dart';
import '../../chat/domain/chat_message.dart';
import '../../chat/domain/chat_tool.dart';
import '../domain/persona.dart';
import '../domain/strict_json_object_parser.dart';
import 'persona_registry.dart';

/// Lets the model switch personality overlays by natural request and create
/// or rewrite personas on demand. save_persona/delete_persona go through the
/// standard confirmation flow: the model prepares a proposal for
/// canonical persona Markdown file, the owner reviews the diff in the memory dialog. The
/// coordinator intercepts these calls before executeTool and routes them
/// through the standard proposal flow.
class PersonaChatTools implements ChatToolRuntime {
  PersonaChatTools({required this.registry});

  final PersonaRegistryAdapter registry;

  static const listPersonas = ChatToolDefinition(
    effect: ChatToolEffect.readOnly,
    name: 'list_personas',
    description:
        'List available persona metadata. Persona prompts are never returned. '
        'user asks which personas exist.',
    parameters: {'type': 'object', 'properties': {}},
  );

  static const switchPersona = ChatToolDefinition(
    effect: ChatToolEffect.mutating,
    name: 'switch_persona',
    description:
        'Activate a persona overlay by canonical id (applied on top of '
        'soul.md), or clear the overlay with id null. Use when the user '
        'asks to become/enable a persona or to turn it off.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': {
          'type': ['string', 'null'],
          'description': 'Persona id from list_personas, or null to reset.',
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
        'Create or update a persona Markdown document. The '
        'user must confirm the exact diff before it is written.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'title': {'type': 'string'},
        'description': {'type': 'string'},
        'params': {'type': 'object'},
        'prompt': {
          'type': 'string',
          'description': 'Full overlay instructions for this persona.',
        },
      },
      'required': ['id', 'title', 'description', 'params', 'prompt'],
      'additionalProperties': false,
    },
  );

  static const deletePersona = ChatToolDefinition(
    effect: ChatToolEffect.runtimeConfirmed,
    name: 'delete_persona',
    description:
        'Remove a persona Markdown document. Requires user '
        'confirmation of the diff.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
      },
      'required': ['id'],
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
          : StrictJsonObjectParser.decode(call.arguments);
      switch (call.name) {
        case 'list_personas':
          _keys(args, const {});
          final catalog = await registry.refresh();
          return jsonEncode({
            'ok': true,
            'active_id': registry.activeId,
            'personas': [for (final e in catalog.personas) e.toJson()],
          });
        case 'switch_persona':
          _keys(args, const {'id'}, allowEmpty: true);
          final rawId = args['id'];
          if (rawId != null && rawId is! String) {
            throw const FormatException(
              'switch_persona id must be string or null',
            );
          }
          final id = rawId as String?;
          final status = await registry.switchTo(id);
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

  static void _keys(
    Map<String, Object?> args,
    Set<String> expected, {
    bool allowEmpty = false,
  }) {
    if ((allowEmpty && args.isEmpty) ||
        (args.length == expected.length &&
            args.keys.toSet().containsAll(expected))) {
      return;
    }
    throw const FormatException('Persona tool arguments do not match schema');
  }
}

final personaChatToolsProvider = Provider<PersonaChatTools>((ref) {
  final registry = ref.watch(personaRegistryAdapterProvider);
  return PersonaChatTools(
    registry: registry ?? const UnavailablePersonaRegistry(),
  );
});

class UnavailablePersonaRegistry implements PersonaRegistryAdapter {
  const UnavailablePersonaRegistry();
  static StateError _error() => StateError('Memory storage is not configured');
  @override
  String? get activeId => null;
  @override
  Future<PersonaCatalog> refresh() async => throw _error();
  @override
  Future<String> switchTo(String? id) async => throw _error();
  @override
  Future<PersonaMutationPreview> previewDelete(String id) async =>
      throw _error();
  @override
  Future<PersonaMutationPreview> previewSave({
    required String id,
    required String title,
    required String description,
    required Map<String, Object?> params,
    required String prompt,
  }) async => throw _error();
}
