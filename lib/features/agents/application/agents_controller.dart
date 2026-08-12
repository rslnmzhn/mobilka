import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../data/agent_catalog_storage.dart';
import '../data/agent_import_picker.dart';
import '../data/agent_metadata_service.dart';
import '../data/agent_metadata_store.dart';
import '../data/selected_agent_prompt_adapter.dart';
import '../domain/agent_catalog.dart';
import '../domain/agent_definition.dart';

part 'agents_controller.g.dart';

@Riverpod(keepAlive: true)
AgentCatalogStorage agentCatalogStorage(Ref ref) => AgentCatalogStorage();

@Riverpod(keepAlive: true)
AgentMetadataService agentMetadataService(Ref ref) =>
    const AgentMetadataService(AgentMetadataStore());

@Riverpod(keepAlive: true)
AgentMetadataStore agentMetadataStore(Ref ref) => const AgentMetadataStore();

@Riverpod(keepAlive: true)
AgentImportPicker agentImportPicker(Ref ref) => AgentImportPicker();

@Riverpod(keepAlive: true)
SelectedAgentPromptAdapter selectedAgentPromptAdapter(Ref ref) =>
    SelectedAgentPromptAdapter(ref.watch(agentsControllerProvider.future));

@Riverpod(keepAlive: true)
class AgentsController extends _$AgentsController {
  @override
  Future<AgentCatalog> build() => _load();

  Future<void> importAgent() => _mutate(() async {
    final definition = await ref.read(agentImportPickerProvider).pick();
    if (definition != null) {
      await ref.read(agentCatalogStorageProvider).importDefinition(definition);
    }
  });

  Future<void> create(AgentDefinition definition) =>
      _mutate(() => ref.read(agentCatalogStorageProvider).create(definition));

  Future<void> edit(String existingId, AgentDefinition definition) => _mutate(
    () async {
      await ref.read(agentCatalogStorageProvider).edit(existingId, definition);
      if (existingId != definition.id) {
        await ref
            .read(agentMetadataServiceProvider)
            .move(existingId, definition.id);
        if (_selectedId == existingId) {
          await _setSelected(definition.id);
        }
      }
    },
  );

  Future<void> delete(String id) => _mutate(() async {
    await ref.read(agentCatalogStorageProvider).delete(id);
    await ref.read(agentMetadataServiceProvider).remove(id);
    if (_selectedId == id) await _setSelected(null);
  });

  Future<void> toggleHidden(AgentCatalogEntry entry) => _mutate(() async {
    final catalog = await _load();
    await ref
        .read(agentMetadataServiceProvider)
        .setHidden(catalog, entry.definition.id, !entry.isHidden);
    if (!entry.isHidden && _selectedId == entry.definition.id) {
      await _setSelected(null);
    }
  });

  Future<void> toggleFavorite(AgentCatalogEntry entry) => _mutate(() async {
    final catalog = await _load();
    await ref
        .read(agentMetadataServiceProvider)
        .setFavorite(catalog, entry.definition.id, !entry.isFavorite);
  });

  Future<void> select(String id) => _mutate(() async {
    final catalog = await _load();
    final entry = catalog.agents
        .where((agent) => agent.definition.id == id)
        .firstOrNull;
    if (entry == null || !entry.isSelectable) {
      throw StateError('Selected agent must be a visible valid primary agent');
    }
    await _setSelected(id);
  });

  AgentMetadataStore get _metadataStore => ref.read(agentMetadataStoreProvider);

  String? get _selectedId => _metadataStore.selectedId;

  Future<void> _setSelected(String? id) => _metadataStore.setSelected(id);

  Future<AgentCatalog> _load() async {
    final metadata = ref.read(agentMetadataServiceProvider);
    final discovery = await ref.read(agentCatalogStorageProvider).discover();
    var selected = _metadataStore.selectedId;
    var catalog = metadata.compose(discovery, selected);
    final selectedValid = catalog.selected?.isSelectable == true;
    if (!_metadataStore.hasSelectedValue) {
      selected = catalog.agents
          .where(
            (entry) =>
                entry.definition.id == 'general-assistant' &&
                entry.isSelectable,
          )
          .firstOrNull
          ?.definition
          .id;
      await _setSelected(selected);
    } else if (!selectedValid && selected != null) {
      selected = null;
      await _setSelected(null);
    }
    catalog = metadata.compose(discovery, selected);
    return catalog;
  }

  Future<void> _mutate(Future<void> Function() operation) async {
    state = const AsyncLoading<AgentCatalog>().copyWithPrevious(state);
    try {
      await operation();
      state = AsyncData(await _load());
    } on Object catch (error, stackTrace) {
      state = AsyncError<AgentCatalog>(
        error,
        stackTrace,
      ).copyWithPrevious(state);
    }
  }
}
