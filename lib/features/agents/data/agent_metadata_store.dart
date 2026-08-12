import '../../../core/storage/app_boxes.dart';

class AgentMetadataStore {
  const AgentMetadataStore();

  static const _hiddenKey = 'agentHidden';
  static const _favoriteKey = 'agentFavorite';
  static const _selectedKey = 'selectedAgentId';

  Map<String, bool> get hidden => _readFlags(_hiddenKey);
  Map<String, bool> get favorites => _readFlags(_favoriteKey);
  String? get selectedId => preferencesBox.get(_selectedKey) as String?;
  bool get hasSelectedValue => preferencesBox.containsKey(_selectedKey);

  Future<void> setHidden(String id, bool value) =>
      _putFlag(_hiddenKey, id, value);

  Future<void> setFavorite(String id, bool value) =>
      _putFlag(_favoriteKey, id, value);

  Future<void> setSelected(String? id) => preferencesBox.put(_selectedKey, id);

  Future<void> remove(String id) async {
    await _removeFlag(_hiddenKey, id);
    await _removeFlag(_favoriteKey, id);
  }

  Future<void> move(String from, String to) async {
    final hiddenValue = hidden[from];
    final favoriteValue = favorites[from];
    await remove(from);
    if (hiddenValue != null) await setHidden(to, hiddenValue);
    if (favoriteValue != null) await setFavorite(to, favoriteValue);
  }

  Map<String, bool> _readFlags(String key) {
    final raw = preferencesBox.get(key);
    if (raw is! Map) return {};
    return {
      for (final entry in raw.entries)
        if (entry.key is String && entry.value is bool)
          entry.key as String: entry.value as bool,
    };
  }

  Future<void> _putFlag(String key, String id, bool value) async {
    final values = _readFlags(key)..[id] = value;
    await preferencesBox.put(key, values);
  }

  Future<void> _removeFlag(String key, String id) async {
    final values = _readFlags(key);
    if (values.remove(id) != null) await preferencesBox.put(key, values);
  }
}
