import 'dart:convert';

import 'package:yaml/yaml.dart';
import 'strict_yaml_preflight.dart';
import 'strict_json_object_parser.dart';

const maxPersonaDocumentBytes = 256 * 1024;
const maxPersonaFrontmatterBytes = 16 * 1024;
const maxPersonas = 128;
const maxPersonaAggregateBytes = 2 * 1024 * 1024;

final RegExp personaSlugPattern = RegExp(
  r'^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$',
);

class PersonaMetadata {
  const PersonaMetadata({
    required this.id,
    required this.title,
    required this.description,
    required this.params,
    this.compatibilityPrompt = '',
  });

  final String id;
  final String title;
  final String description;
  final Map<String, Object?> params;
  final String compatibilityPrompt;
  String get name => id;
  String get text => compatibilityPrompt;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'params': params,
  };
}

class PersonaDefinition {
  const PersonaDefinition({required this.metadata, required this.prompt});
  final PersonaMetadata metadata;
  final String prompt;
}

class PersonaCatalogIssue {
  const PersonaCatalogIssue({required this.fileName, required this.message});
  final String fileName;
  final String message;
}

class PersonaCatalog {
  const PersonaCatalog({required this.personas, required this.issues});
  final List<PersonaMetadata> personas;
  final List<PersonaCatalogIssue> issues;
  Iterable<T> map<T>(T Function(PersonaMetadata) transform) =>
      personas.map(transform);
  PersonaMetadata get single => personas.single;
  PersonaMetadata get first => personas.first;
  bool get isEmpty => personas.isEmpty;
}

class PersonaDocumentCodec {
  const PersonaDocumentCodec();

  PersonaDefinition parse(String slug, String source) {
    if (!personaSlugPattern.hasMatch(slug)) {
      throw const FormatException('Invalid persona ID');
    }
    final bytes = utf8.encode(source);
    if (bytes.length > maxPersonaDocumentBytes) {
      throw const FormatException('Persona document exceeds 256 KiB');
    }
    final normalized = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (!normalized.startsWith('---\n')) {
      throw const FormatException('Required YAML frontmatter is missing');
    }
    final end = normalized.indexOf('\n---\n', 4);
    if (end < 0) throw const FormatException('Frontmatter is not terminated');
    final frontmatter = normalized.substring(4, end);
    if (utf8.encode(frontmatter).length > maxPersonaFrontmatterBytes) {
      throw const FormatException('Persona frontmatter exceeds 16 KiB');
    }
    final lines = const LineSplitter().convert(frontmatter);
    const keys = ['id', 'title', 'description', 'params'];
    if (lines.length != keys.length) {
      throw const FormatException('Frontmatter must use four canonical lines');
    }
    for (var index = 0; index < keys.length; index++) {
      if (!lines[index].startsWith('${keys[index]}:')) {
        throw const FormatException('Frontmatter keys are not canonical');
      }
    }
    StrictYamlPreflight.validate(
      frontmatter,
      maxBytes: maxPersonaFrontmatterBytes,
    );
    final paramsMatch = RegExp(r'^params: (\{.*\})$').firstMatch(lines[3]);
    if (paramsMatch == null) {
      throw const FormatException('params must be one-line JSON object');
    }
    final strictParams = StrictJsonObjectParser(paramsMatch.group(1)!).parse();
    final Object? loaded;
    try {
      loaded = loadYaml(frontmatter);
    } on Object catch (error) {
      throw FormatException('Malformed persona frontmatter: $error');
    }
    if (loaded is! Map) {
      throw const FormatException('Frontmatter must be a map');
    }
    final map = <String, Object?>{};
    for (final entry in loaded.entries) {
      if (entry.key is! String || map.containsKey(entry.key)) {
        throw const FormatException('Frontmatter keys must be unique strings');
      }
      map[entry.key as String] = _plain(entry.value, depth: 0, entries: [0]);
    }
    if (map.keys.toSet().difference(const {
          'id',
          'title',
          'description',
          'params',
        }).isNotEmpty ||
        !map.keys.toSet().containsAll(const {
          'id',
          'title',
          'description',
          'params',
        })) {
      throw const FormatException(
        'Frontmatter requires only id, title, description, params',
      );
    }
    final id = map['id'];
    final title = map['title'];
    final description = map['description'];
    final params = strictParams;
    if (id is! String || id != slug) {
      throw const FormatException('Persona id must equal file slug');
    }
    if (title is! String || title.trim().isEmpty || title.length > 120) {
      throw const FormatException('Persona title is invalid');
    }
    if (description is! String || description.length > 1000) {
      throw const FormatException('Persona description is invalid');
    }
    final prompt = normalized.substring(end + 5);
    if (prompt.trim().isEmpty) {
      throw const FormatException('Persona prompt is empty');
    }
    return PersonaDefinition(
      metadata: PersonaMetadata(
        id: id,
        title: title,
        description: description,
        params: Map.unmodifiable(params),
      ),
      prompt: prompt,
    );
  }

  String serialize(PersonaDefinition definition) {
    final metadata = definition.metadata;
    final jsonParams = jsonEncode(metadata.params);
    final result =
        '---\n'
        'id: ${jsonEncode(metadata.id)}\n'
        'title: ${jsonEncode(metadata.title)}\n'
        'description: ${jsonEncode(metadata.description)}\n'
        'params: $jsonParams\n'
        '---\n${definition.prompt.replaceAll('\r\n', '\n').replaceAll('\r', '\n')}';
    final canonical = result.endsWith('\n') ? result : '$result\n';
    parse(metadata.id, canonical);
    return canonical;
  }

  Object? _plain(
    Object? value, {
    required int depth,
    required List<int> entries,
  }) {
    if (depth > 8 || ++entries[0] > 512) {
      throw const FormatException('Persona params exceed complexity limits');
    }
    if (value == null || value is String || value is bool || value is num) {
      return value;
    }
    if (value is YamlList || value is List) {
      return List<Object?>.unmodifiable(
        (value as Iterable).map(
          (item) => _plain(item, depth: depth + 1, entries: entries),
        ),
      );
    }
    if (value is Map) {
      final result = <String, Object?>{};
      for (final entry in value.entries) {
        if (entry.key is! String || result.containsKey(entry.key)) {
          throw const FormatException(
            'Persona params keys must be unique strings',
          );
        }
        result[entry.key as String] = _plain(
          entry.value,
          depth: depth + 1,
          entries: entries,
        );
      }
      return Map<String, Object?>.unmodifiable(result);
    }
    throw const FormatException('Persona params contain an unsupported value');
  }
}
