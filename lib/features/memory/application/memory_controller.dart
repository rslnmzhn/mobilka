import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/logging/app_logger.dart';
import 'update_memory_file_service.dart';
import 'memory_mutation_coordinator.dart';
import '../data/memory_repository.dart';

part 'memory_controller.g.dart';

@riverpod
class MemoryController extends _$MemoryController {
  @override
  Future<MemoryLocation?> build() async {
    final location = ref.watch(memoryRepositoryProvider).savedLocation();
    await ref.read(memoryMutationCoordinatorProvider)?.recover();
    await ref.read(updateMemoryFileProvider)?.recoverProposals();
    return location;
  }

  Future<void> chooseFolder() async {
    final logger = ref.read(appLoggerProvider);
    final stopwatch = Stopwatch()..start();
    logger.log(event: 'memory.folder_selection', status: 'started');
    final result = await AsyncValue.guard(
      () => ref.read(memoryRepositoryProvider).chooseAndInitialize(),
    );
    if (result.hasError) {
      logger.log(
        event: 'memory.folder_selection',
        level: AppLogLevel.error,
        status: 'failed',
        error: result.error,
        duration: stopwatch.elapsed,
      );
      state = result;
      return;
    }
    final location = result.valueOrNull;
    if (location == null) {
      logger.log(
        event: 'memory.folder_selection',
        status: 'cancelled',
        duration: stopwatch.elapsed,
      );
      return;
    }

    state = AsyncData(location);
    ref.invalidate(memoryMutationCoordinatorProvider);
    ref.invalidate(updateMemoryFileProvider);
    logger.log(
      event: 'memory.folder_selection',
      status: 'succeeded',
      duration: stopwatch.elapsed,
    );
  }
}
