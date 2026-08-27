import 'dart:convert';

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

  /// Leaves headroom below the 1 MiB boundary limit for guard markers and
  /// later journal/audit writes. The agent must compact rather than lose data.
  static const softUtf8ByteLimit = 768 * 1024;

  Future<String> write(String content) async {
    final guarded = _guard.sanitize(content);
    if (utf8.encode(guarded.content).length > softUtf8ByteLimit) {
      throw StateError(
        'memory.md is above the 768 KiB working limit after safety markers. '
        'Compact the memory and try again; content was not truncated.',
      );
    }
    await _mutations.mutate(
      event: 'memory.instant_write',
      replacements: {MemoryFiles.memory: guarded.content},
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
