import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import '../domain/agent_definition.dart';
import 'agent_definition_parser.dart';

typedef AgentFilePicker = Future<XFile?> Function();

class AgentImportPicker {
  AgentImportPicker({
    AgentDefinitionParser parser = const AgentDefinitionParser(),
    AgentFilePicker? picker,
  }) : _parser = parser,
       _picker = picker ?? _pickMarkdown;

  final AgentDefinitionParser _parser;
  final AgentFilePicker _picker;

  Future<AgentDefinition?> pick() async {
    final file = await _picker();
    if (file == null) return null;
    if (await file.length() > AgentDefinitionParser.maxDocumentBytes) {
      throw const AgentDefinitionFormatException('Agent document is too large');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(
      0,
      AgentDefinitionParser.maxDocumentBytes + 1,
    )) {
      bytes.add(chunk);
      if (bytes.length > AgentDefinitionParser.maxDocumentBytes) {
        throw const AgentDefinitionFormatException(
          'Agent document is too large',
        );
      }
    }
    return _parser.parse(utf8.decode(bytes.takeBytes()));
  }

  static Future<XFile?> _pickMarkdown() => openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Markdown agent', extensions: ['md']),
    ],
  );
}
