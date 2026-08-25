import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/memory_repository.dart';
import '../domain/memory_file_names.dart';
import 'memory_mutation_coordinator.dart';
import 'prompt_guard.dart';

/// Applies the agent's working notes to memory.md instantly, bypassing the
/// confirmation proposal flow (roadmap Memory 2.0). Content passes through
/// [PromptGuard] so injected instructions get marked before hitting disk.
class InstantMemoryWriter {
  InstantMemoryWriter(
    this._mutations, {
    PromptGuard guard = const PromptGuard(),
  }) : _guard = guard;

  final MemoryMutationCoordinator _mutations;
  final PromptGuard _guard;

  Future<String> write(String content) async {
    final guarded = _guard.sanitize(content);
    await _mutations.mutate(
      event: 'memory.instant_write',
      replacements: {MemoryFiles.memory: guarded.content},
      createIfMissing: {MemoryFiles.memory},
    );
    return guarded.hasSuspectedInjection
        ? 'written with [suspected-injection] markers'
        : 'written';
  }
}

final instantMemoryWriterProvider = Provider<InstantMemoryWriter?>((ref) {
  final repository = ref.watch(memoryRepositoryProvider);
  final location = repository.savedLocation();
  final mutations = ref.watch(memoryMutationCoordinatorProvider);
  if (location == null || mutations == null) return null;
  return InstantMemoryWriter(mutations);
});
