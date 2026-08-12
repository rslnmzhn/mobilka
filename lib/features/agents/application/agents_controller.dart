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
AgentImportPicker agentImportPicker(Ref ref) => AgentImportPicker();

@Riverpod(keepAlive: true)
SelectedAgentPromptAdapter selectedAgentPromptAdapter(Ref ref) =>
    SelectedAgentPromptAdapter(
      ref.watch(agentCatalogStorageProvider),
      ref.watch(agentMetadataServiceProvider),
    );

@riverpod
class AgentsController extends _$AgentsController {
  @override
  Future<AgentCatalog> build() => _load();

  Future<void> refresh() => _mutate(() async {});

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
      }
    },
  );

  Future<void> delete(String id) => _mutate(() async {
    await ref.read(agentCatalogStorageProvider).delete(id);
    await ref.read(agentMetadataServiceProvider).remove(id);
  });

  Future<void> toggleHidden(AgentCatalogEntry entry) => _mutate(() async {
    final catalog = await _load();
    await ref
        .read(agentMetadataServiceProvider)
        .setHidden(catalog, entry.definition.id, !entry.isHidden);
  });

  Future<void> toggleFavorite(AgentCatalogEntry entry) => _mutate(() async {
    final catalog = await _load();
    await ref
        .read(agentMetadataServiceProvider)
        .setFavorite(catalog, entry.definition.id, !entry.isFavorite);
  });

  Future<void> select(String id) => _mutate(() async {
    await ref.read(agentMetadataServiceProvider).select(await _load(), id);
  });

  Future<AgentCatalog> _load() async => ref
      .read(agentMetadataServiceProvider)
      .compose(await ref.read(agentCatalogStorageProvider).discover());

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
