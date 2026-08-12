import '../domain/agent_catalog.dart';
import 'agent_metadata_store.dart';

class AgentMetadataService {
  const AgentMetadataService(this._store);

  final AgentMetadataStore _store;

  Future<AgentCatalog> compose(AgentDiscoveryResult discovery) async {
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
    var selected = _store.selectedId;
    bool valid(String? id) =>
        entries.any((entry) => entry.definition.id == id && entry.isSelectable);
    if (!_store.hasSelectedValue) {
      final fallback = entries
          .where((entry) => entry.definition.id == 'general-assistant')
          .firstOrNull;
      selected = fallback?.isSelectable == true
          ? fallback!.definition.id
          : null;
      await _store.setSelected(selected);
    } else if (!valid(selected)) {
      selected = null;
      if (_store.selectedId != null) await _store.setSelected(null);
    }
    return AgentCatalog(
      agents: List.unmodifiable(entries),
      issues: discovery.issues,
      selectedId: selected,
    );
  }

  Future<void> setHidden(AgentCatalog catalog, String id, bool value) async {
    _requireKnown(catalog, id);
    await _store.setHidden(id, value);
    if (value && _store.selectedId == id) await _store.setSelected(null);
  }

  Future<void> setFavorite(AgentCatalog catalog, String id, bool value) async {
    _requireKnown(catalog, id);
    await _store.setFavorite(id, value);
  }

  Future<void> select(AgentCatalog catalog, String id) async {
    final entry = catalog.agents
        .where((agent) => agent.definition.id == id)
        .firstOrNull;
    if (entry == null || !entry.isSelectable) {
      throw StateError('Selected agent must be a visible valid primary agent');
    }
    await _store.setSelected(id);
  }

  Future<void> remove(String id) => _store.remove(id);
  Future<void> move(String from, String to) async {
    final selected = _store.selectedId == from;
    await _store.move(from, to);
    if (selected) await _store.setSelected(to);
  }

  void _requireKnown(AgentCatalog catalog, String id) {
    if (!catalog.agents.any((entry) => entry.definition.id == id)) {
      throw StateError('Unknown agent: $id');
    }
  }
}
