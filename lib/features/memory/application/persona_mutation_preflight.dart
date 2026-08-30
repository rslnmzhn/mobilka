import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../data/memory_file_store.dart';
import '../domain/persona.dart';

/// Stateless validation for a projected persona-tree mutation.
///
/// The caller owns locking, recovery, journaling, and all mutations. This
/// helper only reads the transaction snapshot and validates its projection.
Future<void> validateExpectedPersonaMembership({
  required MemoryFileTransaction files,
  required String expectedMembership,
  required Never Function() stale,
}) async {
  if (files is! PersonaTreeTransaction) {
    stale();
  }
  final names = await (files as PersonaTreeTransaction).listPersonaFiles();
  names.sort();
  if (checksum(names.join('\n')) != expectedMembership) {
    stale();
  }
}

Future<void> validatePersonaQuotaProjection({
  required MemoryFileTransaction files,
  required Map<String, String> replacements,
  required Set<String> deletions,
}) async {
  if (!replacements.keys.any(_isPersonaPath) &&
      !deletions.any(_isPersonaPath)) {
    return;
  }
  if (files is! PersonaTreeTransaction) {
    throw StateError('Persona tree is unsupported');
  }

  final contents = <String, String>{};
  for (final name
      in await (files as PersonaTreeTransaction).listPersonaFiles()) {
    final path = 'personas/$name';
    contents[path] = await files.read(path);
  }
  contents.removeWhere((name, _) => deletions.contains(name));
  for (final entry in replacements.entries) {
    if (_isPersonaPath(entry.key)) contents[entry.key] = entry.value;
  }
  final aggregate = contents.values.fold<int>(
    0,
    (total, content) => total + utf8.encode(content).length,
  );
  if (contents.length > maxPersonas || aggregate > maxPersonaAggregateBytes) {
    throw StateError('Persona storage quota exceeded');
  }
}

bool _isPersonaPath(String name) => name.startsWith('personas/');

String checksum(String content) =>
    sha256.convert(utf8.encode(content)).toString();
