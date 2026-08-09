import '../../../core/storage/app_boxes.dart';
import 'memory_repository.dart';

class MemorySelectionStore {
  Set<String> load() => Set<String>.from(
    preferencesBox.get(
          'selectedMemoryFiles',
          defaultValue: MemoryRepository.templates.keys.toList(),
        )
        as List,
  );

  Future<void> save(Set<String> files) => preferencesBox.put(
    'selectedMemoryFiles',
    files.where(MemoryRepository.templates.containsKey).toList(),
  );
}
