import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../data/memory_repository.dart';

part 'memory_controller.g.dart';

@riverpod
class MemoryController extends _$MemoryController {
  @override
  Future<MemoryLocation?> build() async =>
      ref.watch(memoryRepositoryProvider).savedLocation();

  Future<void> chooseFolder() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(memoryRepositoryProvider).chooseAndInitialize(),
    );
  }
}
