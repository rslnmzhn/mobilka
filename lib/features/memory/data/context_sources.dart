import '../../../core/logging/app_logger.dart';
import '../application/context_injector.dart';
import '../application/memory_mutation_coordinator.dart';
import 'memory_repository.dart';

class StoredMemoryContextSource implements MemoryContextSource {
  StoredMemoryContextSource(this._repository, this._coordinator);

  final MemoryRepository _repository;

  /// Resolved lazily so a consumer created before the memory folder was
  /// configured still picks up the coordinator after invalidation.
  final MemoryMutationCoordinator? Function() _coordinator;

  @override
  Future<Map<String, String>> readSnapshot(Iterable<String> fileNames) async {
    final location = _repository.savedLocation();
    if (location == null) return const {};
    final mutations =
        _coordinator() ??
        createMemoryMutationCoordinator(
          repository: _repository,
          location: location,
          logger: AppLogger(),
        );
    return mutations.readContextSnapshot(fileNames);
  }
}
