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

class PersonaRegistryState {
  const PersonaRegistryState({
    required this.entries,
    required this.activeName,
    required this.error,
  });

  final List<PersonaEntry> entries;
  final String? activeName;
  final String? error;
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
    String? content;
    try {
      content = await _readYaml();
    } on Object catch (error) {
      lastError = error.toString();
      return _cached;
    }
    if (content == null) {
      lastError = 'personas.yaml could not be read';
      return _cached;
    }
    _cached = _parse(content);
    if (lastError == null) {
      final active = activeName;
      if (active != null && !_cached.any((entry) => entry.name == active)) {
        _writeActive(null);
      }
    }
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
    if (yamlContent.trim().isEmpty) {
      lastError = null;
      return const [];
    }
    try {
      final doc = loadYaml(yamlContent);
      final root = doc is Map ? doc['personas'] : null;
      if (root is! Map) {
        throw const FormatException('personas.yaml: missing "personas" map');
      }
      final result = _strictEntries(root);
      lastError = null;
      return result;
    } on Object catch (error) {
      lastError = error.toString();
      return const [];
    }
  }

  List<PersonaEntry> _strictEntries(Map<dynamic, dynamic> root) {
    final result = <PersonaEntry>[];
    final names = <String>{};
    for (final entry in root.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const FormatException(
          'personas.yaml: persona names and values must be string scalars',
        );
      }
      final name = entry.key as String;
      final text = entry.value as String;
      if (name.trim().isEmpty) {
        throw const FormatException('personas.yaml: empty persona name');
      }
      _rejectUnsupportedControls(name, field: 'name');
      _rejectUnsupportedControls(text, field: 'value');
      if (!names.add(name)) {
        throw FormatException('personas.yaml: duplicate persona name: $name');
      }
      result.add(PersonaEntry(name: name, text: text));
    }
    return result;
  }
}

final personaRegistryProvider = Provider<PersonaRegistry>((ref) {
  ref.watch(memoryLocationRevisionProvider);
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

  /// Returns the full personas.yaml content after applying the edit.
  Future<String> yamlAfter({
    required String operation,
    required String name,
    required String text,
  });
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

  @override
  Future<String> yamlAfter({
    required String operation,
    required String name,
    required String text,
  }) async {
    if (name.trim().isEmpty) {
      throw const FormatException('Persona name must not be empty');
    }
    if (operation != 'save_persona' && operation != 'delete_persona') {
      throw FormatException('Unknown persona operation: $operation');
    }
    final entries = await _registry.refresh();
    if (_registry.lastError != null) {
      throw FormatException('Cannot modify malformed personas.yaml');
    }
    final map = {for (final e in entries) e.name: e.text};
    if (operation == 'save_persona') {
      map[name] = text;
    } else if (operation == 'delete_persona') {
      map.remove(name);
    }
    if (map.isEmpty) return _validateGenerated('personas: {}\n', map);
    final buf = StringBuffer('personas:\n');
    final names = map.keys.toList()..sort();
    for (final key in names) {
      buf.writeln('  ${_yamlQuote(key)}: ${_yamlQuote(map[key]!)}');
    }
    return _validateGenerated(buf.toString(), map);
  }

  String _validateGenerated(String yaml, Map<String, String> expected) {
    final parsed = _registry._parse(yaml);
    if (_registry.lastError != null ||
        parsed.length != expected.length ||
        parsed.any((entry) => expected[entry.name] != entry.text)) {
      throw const FormatException('Generated personas.yaml failed validation');
    }
    return yaml;
  }

  String _yamlQuote(String value) =>
      '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n').replaceAll('\r', '\\r')}"';
}

void _rejectUnsupportedControls(String value, {required String field}) {
  for (final rune in value.runes) {
    if ((rune < 0x20 && rune != 0x09 && rune != 0x0a && rune != 0x0d) ||
        rune == 0x7f) {
      throw FormatException(
        'personas.yaml: unsupported control character in persona $field',
      );
    }
  }
}

class PersonaRegistryNotifier extends AsyncNotifier<PersonaRegistryState> {
  PersonaRegistry get _registry => ref.read(personaRegistryProvider);

  @override
  Future<PersonaRegistryState> build() async {
    ref.watch(memoryLocationRevisionProvider);
    final registry = ref.watch(personaRegistryProvider);
    final entries = await registry.refresh();
    return _snapshot(registry, entries);
  }

  Future<List<PersonaEntry>> refresh() async {
    final registry = _registry;
    final entries = await registry.refresh();
    state = AsyncData(_snapshot(registry, entries));
    return entries;
  }

  Future<String> switchTo(String? name) async {
    final registry = _registry;
    final result = await registry.switchTo(name);
    final entries = await registry.refresh();
    state = AsyncData(_snapshot(registry, entries));
    return result;
  }

  PersonaRegistryState _snapshot(
    PersonaRegistry registry,
    List<PersonaEntry> entries,
  ) => PersonaRegistryState(
    entries: List.unmodifiable(entries),
    activeName: registry.activeName,
    error: registry.lastError,
  );
}

final personaRegistryStateProvider =
    AsyncNotifierProvider<PersonaRegistryNotifier, PersonaRegistryState>(
      PersonaRegistryNotifier.new,
    );

class ReactivePersonaRegistryAdapter implements PersonaRegistryAdapter {
  ReactivePersonaRegistryAdapter(this.ref);

  final Ref ref;

  PersonaRegistry get _registry => ref.read(personaRegistryProvider);

  @override
  String? get activeName => _registry.activeName;

  @override
  Future<List<PersonaEntry>> refresh() =>
      ref.read(personaRegistryStateProvider.notifier).refresh();

  @override
  Future<String> switchTo(String? name) =>
      ref.read(personaRegistryStateProvider.notifier).switchTo(name);

  @override
  Future<String> yamlAfter({
    required String operation,
    required String name,
    required String text,
  }) => PersonaRegistryAdapterImpl(
    _registry,
  ).yamlAfter(operation: operation, name: name, text: text);
}

final personaRegistryAdapterProvider = Provider<PersonaRegistryAdapter>(
  ReactivePersonaRegistryAdapter.new,
);
