import '../application/context_injector.dart';
import '../application/memory_mutation_coordinator.dart';
import 'memory_repository.dart';

class StoredMemoryContextSource implements MemoryContextSource {
  StoredMemoryContextSource(this._repository, this._mutations);

  final MemoryRepository _repository;
  final MemoryMutationCoordinator? _mutations;

  @override
  Future<Map<String, String>> readSnapshot(Iterable<String> fileNames) async {
    final location = _repository.savedLocation();
    if (location == null) return const {};
    final mutations = _mutations;
    if (mutations == null) {
      throw StateError('Memory recovery is unavailable for configured storage');
    }
    return mutations.readContextSnapshot(fileNames);
  }
}
