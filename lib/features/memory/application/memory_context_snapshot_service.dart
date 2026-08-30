import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/memory_file_store.dart';
import '../data/memory_repository.dart';
import '../domain/memory_file_names.dart';
import '../domain/persona.dart';
import 'memory_mutation_coordinator.dart';
import 'memory_readiness_service.dart';
import 'persona_registry.dart';

final class MemoryContextSnapshot {
  const MemoryContextSnapshot({
    required this.soul,
    required this.user,
    required this.activePersonaId,
    required this.personaPrompt,
  });

  final String? soul;
  final String? user;
  final String? activePersonaId;
  final String? personaPrompt;
}

abstract interface class MemoryContextSnapshotSource {
  Future<MemoryContextSnapshot> read();
}

class MemoryContextSnapshotService implements MemoryContextSnapshotSource {
  MemoryContextSnapshotService({
    required Future<void> Function() ready,
    required MemoryMutationCoordinator? Function() mutations,
    required String? Function() readActiveId,
    Future<void> Function()? clearActiveId,
    PersonaDocumentCodec codec = const PersonaDocumentCodec(),
  }) : _ready = ready,
       _mutations = mutations,
       _readActiveId = readActiveId,
       _clearActiveId = clearActiveId ?? (() async {}),
       _codec = codec;

  final Future<void> Function() _ready;
  final MemoryMutationCoordinator? Function() _mutations;
  final String? Function() _readActiveId;
  final Future<void> Function() _clearActiveId;
  final PersonaDocumentCodec _codec;

  @override
  Future<MemoryContextSnapshot> read() async {
    await _ready();
    final coordinator = _mutations();
    if (coordinator == null) {
      return const MemoryContextSnapshot(
        soul: null,
        user: null,
        activePersonaId: null,
        personaPrompt: null,
      );
    }
    return coordinator.transaction((files) async {
      // This persisted value is intentionally captured at the transaction
      // boundary before any source file is read.
      final activeId = _readActiveId();
      final soul = await _read(files, MemoryFiles.soul);
      final user = await _read(files, MemoryFiles.user);
      String? prompt;
      if (activeId != null) {
        final source = personaSlugPattern.hasMatch(activeId)
            ? await _read(files, 'personas/$activeId.md')
            : null;
        if (source == null) {
          await _clearActiveId();
          return MemoryContextSnapshot(
            soul: soul,
            user: user,
            activePersonaId: null,
            personaPrompt: null,
          );
        }
        try {
          prompt = _codec.parse(activeId, source).prompt;
        } on FormatException {
          await _clearActiveId();
          return MemoryContextSnapshot(
            soul: soul,
            user: user,
            activePersonaId: null,
            personaPrompt: null,
          );
        }
      }
      return MemoryContextSnapshot(
        soul: soul,
        user: user,
        activePersonaId: activeId,
        personaPrompt: prompt,
      );
    });
  }

  static Future<String?> _read(MemoryFileTransaction files, String path) async {
    if (files is MissingAwareMemoryFileTransaction) {
      return (files as MissingAwareMemoryFileTransaction).readIfExists(path);
    }
    try {
      return await files.read(path);
    } on Object {
      return null;
    }
  }
}

final memoryContextSnapshotServiceProvider =
    Provider<MemoryContextSnapshotSource>((ref) {
      ref.watch(memoryLocationRevisionProvider);
      return MemoryContextSnapshotService(
        ready: () => ref.read(memoryLocationReadyProvider.future),
        mutations: () => ref.read(memoryMutationCoordinatorProvider),
        readActiveId: () => ref.read(personaRegistryProvider)?.activeId,
        clearActiveId: () async =>
            ref.read(personaRegistryProvider)?.switchTo(null),
      );
    }, name: 'memory_context_snapshot_service');
