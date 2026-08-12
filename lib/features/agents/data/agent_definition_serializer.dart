import 'dart:convert';

import '../domain/agent_definition.dart';
import 'agent_definition_parser.dart';

class AgentDefinitionSerializer {
  const AgentDefinitionSerializer({
    this.parser = const AgentDefinitionParser(),
  });

  final AgentDefinitionParser parser;

  String serialize(AgentDefinition definition) {
    final buffer = StringBuffer()
      ..writeln('---')
      ..writeln('id: ${jsonEncode(definition.id)}')
      ..writeln('name: ${jsonEncode(definition.name)}')
      ..writeln('description: ${jsonEncode(definition.description)}')
      ..writeln('mode: ${definition.mode.name}');
    final model = definition.modelPreference;
    if (model != null) buffer.writeln('model_preference: ${jsonEncode(model)}');
    _writeList(buffer, 'subagents', definition.subagents);
    _writeList(buffer, 'tools', definition.tools);
    buffer
      ..writeln('---')
      ..write(definition.prompt);
    final document = buffer.toString();
    parser.parse(document);
    return document;
  }

  void _writeList(StringBuffer buffer, String key, List<String> values) {
    if (values.isEmpty) return;
    buffer.writeln('$key:');
    for (final value in values) {
      buffer.writeln('  - ${jsonEncode(value)}');
    }
  }
}
