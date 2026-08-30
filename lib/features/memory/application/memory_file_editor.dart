import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/memory_file_store.dart';
import '../data/memory_repository.dart';
import '../domain/memory_file_names.dart';
import 'memory_mutation_coordinator.dart';
import 'memory_readiness_service.dart';

final memoryFileEditorProvider = Provider<MemoryFileEditor?>((ref) {
  final repository = ref.watch(memoryRepositoryProvider);
  final location = repository.savedLocation();
  final mutations = ref.watch(memoryMutationCoordinatorProvider);
  if (location == null || mutations == null) return null;
  return MemoryFileEditor(
    repository.boundaryFor(location),
    mutations,
    ready: () => ref.read(memoryLocationReadyProvider.future),
  );
}, name: 'memory_file_editor');

class MemoryFileEditor {
  MemoryFileEditor(
    this._boundary,
    this._mutations, {
    Future<void> Function()? ready,
  }) : _ready = ready ?? (() => Future<void>.value());

  final MemoryFileBoundary _boundary;
  final MemoryMutationCoordinator _mutations;
  final Future<void> Function() _ready;

  Future<MemoryEditSnapshot> read(String fileName) async {
    _validate(fileName);
    await _ready();
    final content = await _boundary.read(fileName);
    return MemoryEditSnapshot(content, checksum(content));
  }

  Future<void> save(
    String fileName,
    String content, {
    required String expectedVersion,
  }) async {
    _validate(fileName);
    await _ready();
    return _mutations.mutate(
      event: 'manual_memory_edit',
      replacements: {fileName: content},
      expectedVersions: {fileName: expectedVersion},
    );
  }

  static void _validate(String fileName) {
    if (!MemoryFiles.ownerEditableFiles.contains(fileName) &&
        !MemoryFileValidation.isPersonaPath(fileName)) {
      throw FormatException('Memory file is not approved: $fileName');
    }
  }
}

class MemoryEditSnapshot {
  const MemoryEditSnapshot(this.content, this.version);
  final String content;
  final String version;
}
