import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'memory_backup_controller.dart';
import 'memory_file_editor.dart';
import 'memory_mutation_coordinator.dart';
import 'update_memory_file_service.dart';
import '../data/memory_repository.dart';

part 'memory_controller.g.dart';

@riverpod
class MemoryController extends _$MemoryController {
  @override
  Future<MemoryLocation?> build() async {
    final location = ref.watch(memoryRepositoryProvider).savedLocation();
    await ref.watch(memoryMutationCoordinatorProvider)?.recover();
    return location;
  }

  Future<void> chooseFolder() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(memoryRepositoryProvider).chooseAndInitialize(),
    );
    ref.invalidate(updateMemoryFileProvider);
    ref.invalidate(memoryFileEditorProvider);
    ref.invalidate(memoryMutationCoordinatorProvider);
    ref.invalidate(memoryBackupControllerProvider);
  }
}
