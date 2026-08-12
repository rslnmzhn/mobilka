import 'dart:convert';

import 'package:mobilka/features/agents/domain/agent_definition.dart';
import 'package:yaml/yaml.dart';

class AgentDefinitionParser {
  const AgentDefinitionParser();

  static const maxDocumentBytes = 256 * 1024;
  static const maxFrontmatterBytes = 16 * 1024;
  static const maxListEntries = 64;

  static final RegExp _safeId = RegExp(
    r'^[a-z0-9](?:[a-z0-9_-]{0,62}[a-z0-9])?$',
  );
  static final RegExp _keyLine = RegExp(r'^([a-z][a-z0-9_]*):(.*)$');
  static final RegExp _listLine = RegExp(r'^  -[ \t]+(.+)$');
  static final RegExp _unsupportedValueStart = RegExp(
    r'^(?:[\[\]{}&*!|>%]|\.\.\.(?:\s|$)|---(?:\s|$)|-[ \t]|\?[ \t])',
  );
  static const _allowedKeys = {
    'id',
    'name',
    'description',
    'mode',
    'model_preference',
    'subagents',
    'tools',
    'hidden',
    'favorite',
  };
  static const _listKeys = {'subagents', 'tools'};

  AgentDefinition parse(String source) {
    if (utf8.encode(source).length > maxDocumentBytes) {
      throw const AgentDefinitionFormatException('Agent document is too large');
    }

    final openingEnd = _openingDelimiterEnd(source);
    final closing = _findClosingDelimiter(source, openingEnd);
    final frontmatter = source.substring(openingEnd, closing.start);
    if (utf8.encode(frontmatter).length > maxFrontmatterBytes) {
      throw const AgentDefinitionFormatException(
        'Agent frontmatter is too large',
      );
    }

    _validateFrontmatterShape(frontmatter);
    final Map<Object?, Object?> values;
    try {
      final document = loadYaml(frontmatter);
      if (document is! YamlMap) {
        throw const AgentDefinitionFormatException(
          'Agent frontmatter must be a YAML mapping',
        );
      }
      values = document;
    } on YamlException catch (error) {
      throw AgentDefinitionFormatException('Malformed YAML: ${error.message}');
    }

    for (final key in values.keys) {
      if (key is! String || !_allowedKeys.contains(key)) {
        throw AgentDefinitionFormatException('Unknown frontmatter field: $key');
      }
    }

    final id = _requiredString(values, 'id', maxLength: 64);
    _requireSafeId(id, 'id');
    final name = _requiredString(values, 'name', maxLength: 120);
    final description = _requiredString(values, 'description', maxLength: 1000);
    final modeValue = _requiredString(values, 'mode', maxLength: 16);
    final mode = switch (modeValue) {
      'primary' => AgentMode.primary,
      'subagent' => AgentMode.subagent,
      _ => throw AgentDefinitionFormatException(
        'Unsupported agent mode: $modeValue',
      ),
    };
    final modelPreference = _optionalString(
      values,
      'model_preference',
      maxLength: 200,
    );
    final subagents = _idList(values, 'subagents');
    final tools = _idList(values, 'tools');
    if (mode == AgentMode.subagent && subagents.isNotEmpty) {
      throw const AgentDefinitionFormatException(
        'A subagent cannot declare subagents',
      );
    }
    if (subagents.contains(id)) {
      throw const AgentDefinitionFormatException(
        'An agent cannot reference itself as a subagent',
      );
    }

    return AgentDefinition(
      id: id,
      name: name,
      description: description,
      mode: mode,
      modelPreference: modelPreference,
      subagents: List.unmodifiable(subagents),
      tools: List.unmodifiable(tools),
      isHidden: _optionalBool(values, 'hidden'),
      isFavorite: _optionalBool(values, 'favorite'),
      prompt: source.substring(closing.bodyStart),
    );
  }

  int _openingDelimiterEnd(String source) {
    if (source.startsWith('---\n')) return 4;
    if (source.startsWith('---\r\n')) return 5;
    throw const AgentDefinitionFormatException(
      'Agent document must start with an exact --- delimiter',
    );
  }

  ({int start, int bodyStart}) _findClosingDelimiter(
    String source,
    int openingEnd,
  ) {
    var lineStart = openingEnd;
    while (lineStart <= source.length) {
      final newline = source.indexOf('\n', lineStart);
      final lineEnd = newline == -1 ? source.length : newline;
      final contentEnd =
          lineEnd > lineStart && source.codeUnitAt(lineEnd - 1) == 13
          ? lineEnd - 1
          : lineEnd;
      if (source.substring(lineStart, contentEnd) == '---') {
        return (
          start: lineStart,
          bodyStart: newline == -1 ? lineEnd : newline + 1,
        );
      }
      if (newline == -1) break;
      lineStart = newline + 1;
    }
    throw const AgentDefinitionFormatException(
      'Agent frontmatter has no closing --- delimiter',
    );
  }

  void _validateFrontmatterShape(String frontmatter) {
    final keys = <String>{};
    String? activeList;
    var activeListHasEntries = false;
    for (final line in const LineSplitter().convert(frontmatter)) {
      if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
      final keyMatch = _keyLine.firstMatch(line);
      if (keyMatch != null) {
        if (activeList != null && !activeListHasEntries) {
          throw AgentDefinitionFormatException(
            '$activeList must contain at least one list entry',
          );
        }
        final key = keyMatch.group(1)!;
        if (!keys.add(key)) {
          throw AgentDefinitionFormatException(
            'Duplicate frontmatter field: $key',
          );
        }
        final value = keyMatch.group(2)!.trimLeft();
        if (_listKeys.contains(key)) {
          if (value.isNotEmpty) {
            throw AgentDefinitionFormatException(
              '$key must use an indented block list',
            );
          }
          activeList = key;
          activeListHasEntries = false;
        } else {
          if (value.isEmpty) {
            throw AgentDefinitionFormatException(
              '$key must use a single-line scalar value',
            );
          }
          _validateScalarSyntax(value);
          activeList = null;
        }
        continue;
      }
      final listMatch = _listLine.firstMatch(line);
      if (listMatch != null && activeList != null) {
        _validateScalarSyntax(listMatch.group(1)!.trimLeft());
        activeListHasEntries = true;
        continue;
      }
      throw AgentDefinitionFormatException(
        'Unsupported frontmatter syntax: ${line.trim()}',
      );
    }
    if (activeList != null && !activeListHasEntries) {
      throw AgentDefinitionFormatException(
        '$activeList must contain at least one list entry',
      );
    }
  }

  void _validateScalarSyntax(String value) {
    final isQuoted = value.startsWith('"') || value.startsWith("'");
    if (_unsupportedValueStart.hasMatch(value) ||
        (!isQuoted && RegExp(r':(?:[ \t]|$)').hasMatch(value))) {
      throw AgentDefinitionFormatException(
        'Unsupported YAML scalar syntax: $value',
      );
    }
  }

  String _requiredString(
    Map<Object?, Object?> values,
    String key, {
    required int maxLength,
  }) {
    if (!values.containsKey(key)) {
      throw AgentDefinitionFormatException('Missing required field: $key');
    }
    return _validateString(values[key], key, maxLength: maxLength);
  }

  String? _optionalString(
    Map<Object?, Object?> values,
    String key, {
    required int maxLength,
  }) {
    if (!values.containsKey(key) || values[key] == null) return null;
    return _validateString(values[key], key, maxLength: maxLength);
  }

  String _validateString(Object? value, String key, {required int maxLength}) {
    if (value is! String || value.trim().isEmpty || value.length > maxLength) {
      throw AgentDefinitionFormatException(
        '$key must be a non-empty string of at most $maxLength characters',
      );
    }
    if (value != value.trim() || value.contains(RegExp(r'[\u0000-\u001f]'))) {
      throw AgentDefinitionFormatException('$key contains invalid whitespace');
    }
    return value;
  }

  List<String> _idList(Map<Object?, Object?> values, String key) {
    final value = values[key];
    if (value == null) return const [];
    if (value is! YamlList || value.length > maxListEntries) {
      throw AgentDefinitionFormatException(
        '$key must be a list with at most $maxListEntries entries',
      );
    }
    final result = <String>[];
    for (final entry in value) {
      final id = _validateString(entry, '$key entry', maxLength: 64);
      _requireSafeId(id, '$key entry');
      if (result.contains(id)) {
        throw AgentDefinitionFormatException('Duplicate $key entry: $id');
      }
      result.add(id);
    }
    return result;
  }

  bool _optionalBool(Map<Object?, Object?> values, String key) {
    final value = values[key];
    if (value == null) return false;
    if (value is! bool) {
      throw AgentDefinitionFormatException('$key must be a boolean');
    }
    return value;
  }

  void _requireSafeId(String value, String field) {
    if (!_safeId.hasMatch(value)) {
      throw AgentDefinitionFormatException('$field is not a safe identifier');
    }
  }
}

class AgentDefinitionFormatException extends FormatException {
  const AgentDefinitionFormatException(super.message);
}
