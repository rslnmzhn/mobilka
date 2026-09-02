import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

import '../data/memory_file_store.dart';
import '../domain/memory_file_names.dart';
import '../domain/persona.dart';
import '../domain/strict_yaml_preflight.dart';
import 'memory_mutation_coordinator.dart';

class LegacyPersonaMigrator {
  const LegacyPersonaMigrator(
    this._mutations, {
    PersonaDocumentCodec codec = const PersonaDocumentCodec(),
  }) : _codec = codec;

  final MemoryMutationCoordinator _mutations;
  final PersonaDocumentCodec _codec;

  Future<void> migrate() async {
    final plan = await _mutations.transaction((files) async {
      if (files is! MissingAwareMemoryFileTransaction) return null;
      final access = files as MissingAwareMemoryFileTransaction;
      final legacy = await access.readIfExists(MemoryFiles.legacyPersonas);
      if (legacy == null) return null;
      final definitions = parseLegacyPersonaDefinitions(legacy);
      final backup = await access.readIfExists(
        MemoryFiles.legacyPersonasBackup,
      );
      if (backup != null && backup != legacy) {
        throw StateError('Persona migration backup conflict');
      }
      final replacements = <String, String>{
        if (backup == null) MemoryFiles.legacyPersonasBackup: legacy,
      };
      final expected = <String, String>{
        MemoryFiles.legacyPersonas: checksum(legacy),
        if (backup != null) MemoryFiles.legacyPersonasBackup: checksum(backup),
      };
      final creates = <String>{
        if (backup == null) MemoryFiles.legacyPersonasBackup,
      };
      for (final definition in definitions) {
        final path = 'personas/${definition.metadata.id}.md';
        final content = _codec.serialize(definition);
        final existing = await access.readIfExists(path);
        if (existing != null && existing != content) {
          throw StateError('Persona migration target conflict: $path');
        }
        if (existing == null) {
          replacements[path] = content;
          creates.add(path);
        } else {
          expected[path] = checksum(existing);
        }
      }
      if (files is! PersonaTreeTransaction) {
        throw StateError('Persona tree is unsupported');
      }
      final membership = [
        ...await (files as PersonaTreeTransaction).listPersonaFiles(),
      ]..sort();
      return (
        legacy: legacy,
        replacements: replacements,
        expected: expected,
        creates: creates,
        membership: checksum(membership.join('\n')),
      );
    });
    if (plan == null) return;
    await _mutations.mutate(
      event: 'persona.legacy_migration',
      replacements: plan.replacements,
      expectedVersions: plan.expected,
      createIfMissing: plan.creates,
      deletions: {MemoryFiles.legacyPersonas},
      additionallyAllowed: {
        MemoryFiles.legacyPersonas,
        MemoryFiles.legacyPersonasBackup,
      },
      expectedPersonaMembership: plan.membership,
    );
  }
}

List<PersonaDefinition> parseLegacyPersonaDefinitions(String source) {
  StrictYamlPreflight.validate(source, maxBytes: 1024 * 1024);
  final loaded = loadYaml(source);
  final root = loaded is Map ? loaded['personas'] : null;
  if (root is! Map) {
    throw const FormatException('Legacy personas map is missing');
  }
  final ids = <String>{};
  final result = <PersonaDefinition>[];
  for (final entry in root.entries) {
    if (entry.key is! String ||
        entry.value is! String ||
        (entry.value as String).trim().isEmpty) {
      throw const FormatException('Legacy personas must be nonempty strings');
    }
    final title = entry.key as String;
    final id = legacyPersonaSlug(title);
    if (!ids.add(id)) {
      throw StateError('Generated persona ID collision: $id');
    }
    result.add(
      PersonaDefinition(
        metadata: PersonaMetadata(
          id: id,
          title: title,
          description: 'Migrated from personas.yaml',
          params: const {},
        ),
        prompt: entry.value as String,
      ),
    );
  }
  return List.unmodifiable(result);
}

String legacyPersonaSlug(String title) {
  final normalized = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (normalized.isNotEmpty) {
    final value = normalized.length <= 64
        ? normalized
        : normalized.substring(0, 64).replaceFirst(RegExp(r'-+$'), '');
    if (personaSlugPattern.hasMatch(value)) return value;
  }
  final hash = sha256.convert(utf8.encode(title)).toString().substring(0, 12);
  return 'persona-$hash';
}
