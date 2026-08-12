import '../domain/agent_catalog.dart';
import 'agent_metadata_store.dart';

class AgentMetadataService {
  const AgentMetadataService(this._store);

  final AgentMetadataStore _store;

  AgentCatalog compose(AgentDiscoveryResult discovery, String? selectedId) {
    final hidden = _store.hidden;
    final favorites = _store.favorites;
    final entries = discovery.documents
        .map(
          (entry) => AgentCatalogEntry(
            definition: entry.definition,
            origin: entry.origin,
            location: entry.location,
            isHidden: hidden[entry.definition.id] ?? false,
            isFavorite: favorites[entry.definition.id] ?? false,
          ),
        )
        .toList();
    entries.sort((a, b) {
      final favorite = (b.isFavorite ? 1 : 0) - (a.isFavorite ? 1 : 0);
      return favorite != 0
          ? favorite
          : a.definition.name.compareTo(b.definition.name);
    });
    return AgentCatalog(
      agents: List.unmodifiable(entries),
      issues: discovery.issues,
      selectedId: selectedId,
    );
  }

  Future<void> setHidden(AgentCatalog catalog, String id, bool value) async {
    _requireKnown(catalog, id);
    await _store.setHidden(id, value);
  }

  Future<void> setFavorite(AgentCatalog catalog, String id, bool value) async {
    _requireKnown(catalog, id);
    await _store.setFavorite(id, value);
  }

  Future<void> remove(String id) => _store.remove(id);
  Future<void> move(String from, String to) => _store.move(from, to);

  void _requireKnown(AgentCatalog catalog, String id) {
    if (!catalog.agents.any((entry) => entry.definition.id == id)) {
      throw StateError('Unknown agent: $id');
    }
  }
}
