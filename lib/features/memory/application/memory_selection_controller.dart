import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../data/memory_selection_store.dart';

part 'memory_selection_controller.g.dart';

final memorySelectionStoreProvider = Provider<MemorySelectionStore>(
  (ref) => MemorySelectionStore(),
  name: 'memory_selection_store',
);

@Riverpod(keepAlive: true)
class MemorySelectionController extends _$MemorySelectionController {
  @override
  Set<String> build() => ref.watch(memorySelectionStoreProvider).load();

  Future<void> setIncluded(String fileName, {required bool included}) async {
    final previous = state;
    final updated = {...state};
    included ? updated.add(fileName) : updated.remove(fileName);
    state = updated;
    try {
      await ref.read(memorySelectionStoreProvider).save(updated);
    } on Object {
      state = previous;
      rethrow;
    }
  }
}
