import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaml/yaml.dart';

import '../../../core/storage/app_boxes.dart';
import '../data/memory_repository.dart';
import '../domain/memory_file_names.dart';

/// One named personality overlay from personas.yaml.
class PersonaEntry {
  const PersonaEntry({required this.name, required this.text});

  final String name;
  final String text;
}

/// Registry of named personality overlays stored in personas.yaml next to the
/// memory files.
///
/// - A missing or malformed personas.yaml yields an empty registry (chat keeps
///   working) with the reason captured in [lastError].
/// - The active persona is persisted in preferences and survives restarts; it
///   changes only through [switchTo] — either to another name or to
///   null/'none'/'default' which clears the overlay.
class PersonaRegistry {
  PersonaRegistry({
    required Future<String?> Function() readYaml,
    required String? Function() readActive,
    required void Function(String? name) writeActive,
  }) : _readYaml = readYaml,
       _readActive = readActive,
       _writeActive = writeActive;

  final Future<String?> Function() _readYaml;
  final String? Function() _readActive;
  final void Function(String? name) _writeActive;

  String? lastError;
  List<PersonaEntry> _cached = const [];

  String? get activeName => _readActive();

  /// Re-reads personas.yaml and returns the parsed entries.
  Future<List<PersonaEntry>> refresh() async {
    final content = await _readYaml();
    _cached = _parse(content ?? '');
    return _cached;
  }

  /// Overlay text for the active persona, or null when none is active or the
  /// persona no longer exists in personas.yaml.
  Future<String?> overlayText() async {
    final name = activeName;
    if (name == null) return null;
    final entries = await refresh();
    for (final entry in entries) {
      if (entry.name == name) return entry.text;
    }
    return null;
  }

  /// Activates [name], or clears the overlay when [name] is null/empty/
  /// 'none'/'default'. Unknown names throw so the tool call turns into a
  /// visible error envelope for the model.
  Future<String> switchTo(String? name) async {
    if (name == null || name.isEmpty || name == 'none' || name == 'default') {
      _writeActive(null);
      await refresh();
      return 'persona cleared';
    }
    final entries = await refresh();
    final exists = entries.any((entry) => entry.name == name);
    if (!exists) {
      throw StateError('Unknown persona: $name');
    }
    _writeActive(name);
    return 'persona set: $name';
  }

  List<PersonaEntry> _parse(String yamlContent) {
    if (yamlContent.trim().isEmpty) return const [];
    try {
      final doc = loadYaml(yamlContent);
      final root = doc is Map ? doc['personas'] : null;
      if (root is! Map) {
        throw const FormatException('personas.yaml: missing "personas" map');
      }
      return [
        for (final entry in root.entries)
          PersonaEntry(
            name: entry.key.toString(),
            text: entry.value?.toString() ?? '',
          ),
      ];
    } on Object catch (error) {
      lastError = error.toString();
      return const [];
    }
  }
}

final personaRegistryProvider = Provider<PersonaRegistry>((ref) {
  final repository = ref.watch(memoryRepositoryProvider);
  final location = repository.savedLocation();
  if (location == null) {
    return PersonaRegistry(
      readYaml: () async => null,
      readActive: () => null,
      writeActive: (_) {},
    );
  }
  final boundary = repository.boundaryFor(location);
  return PersonaRegistry(
    readYaml: () async {
      try {
        return await boundary.read(MemoryFiles.personas);
      } on Object {
        return null;
      }
    },
    readActive: () {
      try {
        return preferencesBox.get('activePersona') as String?;
      } on Object {
        return null;
      }
    },
    writeActive: (name) {
      try {
        preferencesBox.put('activePersona', name);
      } on Object {
        // Persistence unavailable (e.g. tests): overlay stays session-only.
      }
    },
  );
});

/// Tool-facing view of the registry.
abstract interface class PersonaRegistryAdapter {
  String? get activeName;

  Future<List<PersonaEntry>> refresh();

  Future<String> switchTo(String? name);
}

class PersonaRegistryAdapterImpl implements PersonaRegistryAdapter {
  PersonaRegistryAdapterImpl(this._registry);

  final PersonaRegistry _registry;

  @override
  String? get activeName => _registry.activeName;

  @override
  Future<List<PersonaEntry>> refresh() => _registry.refresh();

  @override
  Future<String> switchTo(String? name) => _registry.switchTo(name);
}

final personaRegistryAdapterProvider = Provider<PersonaRegistryAdapter>(
  (ref) => PersonaRegistryAdapterImpl(ref.watch(personaRegistryProvider)),
);
