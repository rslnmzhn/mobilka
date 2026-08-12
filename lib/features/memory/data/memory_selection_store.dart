import '../../../core/storage/app_boxes.dart';
import 'memory_repository.dart';

typedef MemorySelectionReader = Object? Function(String key, Object? fallback);
typedef MemorySelectionWriter = Future<void> Function(String key, Object value);

class MemorySelectionStore {
  MemorySelectionStore({
    MemorySelectionReader? read,
    MemorySelectionWriter? write,
  }) : _read = read ?? _readPreference,
       _write = write ?? _writePreference;

  final MemorySelectionReader _read;
  final MemorySelectionWriter _write;

  Set<String> load() {
    final stored = _read(
      'selectedMemoryFiles',
      MemoryRepository.templates.keys.toList(),
    );
    if (stored is! List) return MemoryRepository.templates.keys.toSet();
    return stored.whereType<String>().where(_isStandardFile).toSet();
  }

  Future<void> save(Set<String> files) =>
      _write('selectedMemoryFiles', files.where(_isStandardFile).toList());

  static bool _isStandardFile(String name) =>
      MemoryRepository.templates.containsKey(name);

  static Object? _readPreference(String key, Object? fallback) =>
      preferencesBox.get(key, defaultValue: fallback);

  static Future<void> _writePreference(String key, Object value) =>
      preferencesBox.put(key, value);
}
