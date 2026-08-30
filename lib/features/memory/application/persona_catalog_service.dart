import 'dart:convert';

import '../data/memory_file_store.dart';
import '../domain/persona.dart';
import 'memory_mutation_coordinator.dart';

class PersonaCatalogService {
  const PersonaCatalogService(
    this._mutations, {
    PersonaDocumentCodec codec = const PersonaDocumentCodec(),
  }) : _codec = codec;

  final MemoryMutationCoordinator _mutations;
  final PersonaDocumentCodec _codec;

  Future<PersonaCatalog> loadCatalog() => _mutations.transaction((files) async {
    if (files is! PersonaTreeTransaction) {
      throw StateError('Persona tree is unsupported');
    }
    final names = await (files as PersonaTreeTransaction).listPersonaFiles();
    if (names.length > maxPersonas) {
      throw StateError('Persona count exceeds $maxPersonas');
    }
    var aggregate = 0;
    final metadata = <PersonaMetadata>[];
    final issues = <PersonaCatalogIssue>[];
    for (final name in names) {
      final source = await files.read('personas/$name');
      aggregate += utf8.encode(source).length;
      if (aggregate > maxPersonaAggregateBytes) {
        throw StateError('Persona catalog exceeds 2 MiB');
      }
      try {
        metadata.add(
          _codec.parse(name.substring(0, name.length - 3), source).metadata,
        );
      } on Object catch (error) {
        final message = error.toString();
        issues.add(
          PersonaCatalogIssue(
            fileName: name,
            message: message.length <= 240
                ? message
                : '${message.substring(0, 240)}…',
          ),
        );
      }
    }
    metadata.sort((left, right) => left.id.compareTo(right.id));
    return PersonaCatalog(
      personas: List.unmodifiable(metadata),
      issues: List.unmodifiable(issues),
    );
  });

  Future<PersonaDefinition?> loadById(String id) async {
    if (!personaSlugPattern.hasMatch(id)) {
      throw const FormatException('Invalid persona ID');
    }
    return _mutations.transaction((files) async {
      final source = files is MissingAwareMemoryFileTransaction
          ? await (files as MissingAwareMemoryFileTransaction).readIfExists(
              'personas/$id.md',
            )
          : await files.read('personas/$id.md');
      return source == null ? null : _codec.parse(id, source);
    });
  }
}
