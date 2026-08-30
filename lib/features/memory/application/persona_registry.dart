import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/memory_repository.dart';
import '../domain/persona.dart';
import 'legacy_persona_migrator.dart';
import 'memory_mutation_coordinator.dart';
import 'persona_active_selection_store.dart';
import 'persona_catalog_service.dart';

class PersonaRegistryState {
  const PersonaRegistryState({required this.catalog});
  final PersonaCatalog catalog;
  List<PersonaMetadata> get entries => catalog.personas;
}

class PersonaMutationPreview {
  const PersonaMutationPreview({
    required this.path,
    required this.content,
    required this.beforeVersion,
    required this.diff,
  });
  final String path;
  final String? content;
  final String beforeVersion;
  final String diff;
}

class PersonaRegistry {
  PersonaRegistry({
    required MemoryMutationCoordinator mutations,
    required PersonaActiveSelectionStore activeSelection,
    PersonaDocumentCodec codec = const PersonaDocumentCodec(),
  }) : _mutations = mutations,
       _activeSelection = activeSelection,
       _codec = codec,
       _catalog = PersonaCatalogService(mutations, codec: codec),
       _migrator = LegacyPersonaMigrator(mutations, codec: codec);

  final MemoryMutationCoordinator _mutations;
  final PersonaActiveSelectionStore _activeSelection;
  final PersonaDocumentCodec _codec;
  final PersonaCatalogService _catalog;
  final LegacyPersonaMigrator _migrator;
  Future<void>? _readiness;

  String? get activeId => _activeSelection.read();
  Future<void> ensureReady() => _readiness ??= _prepareLocation();

  Future<void> _prepareLocation() async {
    await _mutations.recover();
    await _migrator.migrate();
    final catalog = await _catalog.loadCatalog();
    final legacyName = _activeSelection.readLegacyName();
    if (legacyName != null) {
      final matches = catalog.personas
          .where((persona) => persona.title == legacyName)
          .toList();
      await _activeSelection.write(
        matches.length == 1 ? matches.single.id : null,
      );
      await _activeSelection.clearLegacyName();
    }
    final active = activeId;
    if (active != null && !catalog.personas.any((item) => item.id == active)) {
      await _activeSelection.write(null);
    }
  }

  Future<PersonaCatalog> refresh() async {
    await ensureReady();
    final catalog = await _catalog.loadCatalog();
    final active = activeId;
    if (active != null &&
        (!catalog.personas.any((item) => item.id == active) ||
            catalog.issues.any((issue) => issue.fileName == '$active.md'))) {
      await _activeSelection.write(null);
    }
    return catalog;
  }

  Future<PersonaDefinition?> loadById(String id) async {
    await ensureReady();
    return _catalog.loadById(id);
  }

  Future<String?> overlayText() async {
    final id = activeId;
    if (id == null) return null;
    return (await loadById(id))?.prompt;
  }

  Future<String> switchTo(String? value) async {
    if (value == null ||
        value.isEmpty ||
        value == 'none' ||
        value == 'default') {
      await _activeSelection.write(null);
      return 'persona cleared';
    }
    final catalog = await refresh();
    var matches = catalog.personas.where((item) => item.id == value).toList();
    if (matches.isEmpty) {
      matches = catalog.personas.where((item) => item.title == value).toList();
    }
    if (matches.length != 1) {
      throw StateError('Unknown or ambiguous persona: $value');
    }
    await _activeSelection.write(matches.single.id);
    return 'persona set: ${matches.single.id}';
  }

  Future<PersonaMutationPreview> previewSave({
    required String id,
    required String title,
    required String description,
    required Map<String, Object?> params,
    required String prompt,
  }) {
    final content = _codec.serialize(
      PersonaDefinition(
        metadata: PersonaMetadata(
          id: id,
          title: title,
          description: description,
          params: params,
        ),
        prompt: prompt,
      ),
    );
    return _preview(id, content);
  }

  Future<PersonaMutationPreview> previewDelete(String id) => _preview(id, null);

  Future<PersonaMutationPreview> _preview(String id, String? after) async {
    await ensureReady();
    if (!personaSlugPattern.hasMatch(id)) {
      throw const FormatException('Invalid persona ID');
    }
    final path = 'personas/$id.md';
    final before = await _mutations.readIfExists(path);
    if (after == null && before == null) {
      throw StateError('Unknown persona: $id');
    }
    return PersonaMutationPreview(
      path: path,
      content: after,
      beforeVersion: before == null ? 'missing' : checksum(before),
      diff: _diff(path, before ?? '', after ?? ''),
    );
  }

  Future<void> saveManual({
    required PersonaDefinition definition,
    required String expectedVersion,
  }) async {
    await ensureReady();
    final path = 'personas/${definition.metadata.id}.md';
    final create = expectedVersion == 'missing';
    await _mutations.mutate(
      event: 'manual_persona_save',
      replacements: {path: _codec.serialize(definition)},
      expectedVersions: create ? const {} : {path: expectedVersion},
      createIfMissing: create ? {path} : const {},
    );
  }

  Future<void> deleteManual(
    String id, {
    required String expectedVersion,
  }) async {
    await ensureReady();
    final path = 'personas/$id.md';
    await _mutations.mutate(
      event: 'manual_persona_delete',
      replacements: const {},
      expectedVersions: {path: expectedVersion},
      deletions: {path},
    );
    if (activeId == id) await _activeSelection.write(null);
  }
}

abstract interface class PersonaRegistryAdapter {
  String? get activeId;
  Future<PersonaCatalog> refresh();
  Future<String> switchTo(String? id);
  Future<PersonaMutationPreview> previewSave({
    required String id,
    required String title,
    required String description,
    required Map<String, Object?> params,
    required String prompt,
  });
  Future<PersonaMutationPreview> previewDelete(String id);
}

class PersonaRegistryAdapterImpl implements PersonaRegistryAdapter {
  PersonaRegistryAdapterImpl(this.registry);
  final PersonaRegistry registry;
  @override
  String? get activeId => registry.activeId;
  @override
  Future<PersonaCatalog> refresh() => registry.refresh();
  @override
  Future<String> switchTo(String? id) => registry.switchTo(id);
  @override
  Future<PersonaMutationPreview> previewSave({
    required String id,
    required String title,
    required String description,
    required Map<String, Object?> params,
    required String prompt,
  }) => registry.previewSave(
    id: id,
    title: title,
    description: description,
    params: params,
    prompt: prompt,
  );
  @override
  Future<PersonaMutationPreview> previewDelete(String id) =>
      registry.previewDelete(id);
}

final personaRegistryProvider = Provider<PersonaRegistry?>((ref) {
  ref.watch(memoryLocationRevisionProvider);
  final repository = ref.watch(memoryRepositoryProvider);
  final location = repository.savedLocation();
  final mutations = ref.watch(memoryMutationCoordinatorProvider);
  if (location == null || mutations == null) return null;
  return PersonaRegistry(
    mutations: mutations,
    activeSelection: ReactivePersonaActiveSelectionStore(ref),
  );
});

class PersonaRegistryNotifier extends AsyncNotifier<PersonaRegistryState> {
  @override
  Future<PersonaRegistryState> build() async {
    ref.watch(memoryLocationRevisionProvider);
    ref.watch(personaRegistryProvider);
    return _load();
  }

  Future<PersonaRegistryState> _load() async {
    final registry = ref.read(personaRegistryProvider);
    if (registry == null) {
      return const PersonaRegistryState(
        catalog: PersonaCatalog(personas: [], issues: []),
      );
    }
    return PersonaRegistryState(catalog: await registry.refresh());
  }

  Future<PersonaCatalog> refresh() async {
    state = const AsyncLoading();
    final next = await AsyncValue.guard(_load);
    state = next;
    return next.requireValue.catalog;
  }

  Future<String> switchTo(String? id) async {
    final registry = ref.read(personaRegistryProvider);
    if (registry == null) throw StateError('Memory storage is not configured');
    final result = await registry.switchTo(id);
    state = AsyncData(await _load());
    return result;
  }
}

final personaRegistryStateProvider =
    AsyncNotifierProvider<PersonaRegistryNotifier, PersonaRegistryState>(
      PersonaRegistryNotifier.new,
    );
final activePersonaIdProvider = Provider<String?>(
  (ref) => ref.watch(activePersonaControllerProvider),
);
final personaRegistryAdapterProvider = Provider<PersonaRegistryAdapter?>((ref) {
  final registry = ref.watch(personaRegistryProvider);
  return registry == null ? null : PersonaRegistryAdapterImpl(registry);
});

String _diff(String path, String before, String after) =>
    '${['--- $path', '+++ $path', ...const LineSplitter().convert(before).map((line) => '-$line'), ...const LineSplitter().convert(after).map((line) => '+$line')].join('\n')}\n';
