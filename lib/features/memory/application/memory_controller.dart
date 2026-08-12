import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'memory_mutation_coordinator.dart';
import '../data/memory_repository.dart';

part 'memory_controller.g.dart';

@riverpod
class MemoryController extends _$MemoryController {
  @override
  Future<MemoryLocation?> build() async {
    final location = ref.watch(memoryRepositoryProvider).savedLocation();
    await ref.read(memoryMutationCoordinatorProvider)?.recover();
    return location;
  }

  Future<void> chooseFolder() async {
    final result = await AsyncValue.guard(
      () => ref.read(memoryRepositoryProvider).chooseAndInitialize(),
    );
    if (result.hasError) {
      state = result;
      return;
    }
    final location = result.valueOrNull;
    if (location == null) return;

    state = AsyncData(location);
    ref.invalidate(memoryMutationCoordinatorProvider);
  }
}
