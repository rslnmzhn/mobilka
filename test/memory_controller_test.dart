import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/memory_controller.dart';
import 'package:mobilka/features/memory/application/memory_file_editor.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/application/update_memory_file_service.dart';
import 'package:mobilka/features/memory/application/memory_update_proposal_authority.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';
import 'package:saf/saf.dart';
import 'support/memory_delete_mixins.dart';

void main() {
  const original = MemoryLocation(value: 'original', isContentUri: false);
  const replacement = MemoryLocation(value: 'replacement', isContentUri: false);

  test(
    'cancelled folder choice leaves location state and services untouched',
    () async {
      final boundary = _MemoryBoundary(Map.of(MemoryRepository.templates));
      final repository = _MemoryRepository(original, boundary, choice: null);
      var coordinatorBuilds = 0;
      final container = ProviderContainer(
        overrides: [
          memoryRepositoryProvider.overrideWithValue(repository),
          memoryUpdateProposalAuthorityProvider.overrideWithValue(
            InMemoryMemoryUpdateProposalAuthority(),
          ),
          memoryMutationCoordinatorProvider.overrideWith((ref) {
            coordinatorBuilds++;
            return MemoryMutationCoordinator(boundary);
          }),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        memoryControllerProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      await container.read(memoryControllerProvider.future);
      final changes = <AsyncValue<MemoryLocation?>>[];
      final stateSubscription = container.listen(
        memoryControllerProvider,
        (_, next) => changes.add(next),
      );
      addTearDown(stateSubscription.close);

      await container.read(memoryControllerProvider.notifier).chooseFolder();
      await container.pump();

      expect(
        container.read(memoryControllerProvider).requireValue?.value,
        'original',
      );
      expect(changes, isEmpty);
      expect(coordinatorBuilds, 1);
    },
  );

  test(
    'cached null update service becomes available after folder choice',
    () async {
      final boundary = _MemoryBoundary(Map.of(MemoryRepository.templates));
      final repository = _MemoryRepository(null, boundary, choice: replacement);
      final container = ProviderContainer(
        overrides: [
          memoryRepositoryProvider.overrideWithValue(repository),
          memoryUpdateProposalAuthorityProvider.overrideWithValue(
            InMemoryMemoryUpdateProposalAuthority(),
          ),
          memoryMutationCoordinatorProvider.overrideWith(
            (ref) => repository.savedLocation() == null
                ? null
                : MemoryMutationCoordinator(boundary),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(updateMemoryFileProvider), isNull);
      await container.read(memoryControllerProvider.future);
      await container.read(memoryControllerProvider.notifier).chooseFolder();

      expect(container.read(updateMemoryFileProvider), isNotNull);
    },
  );

  test(
    'successful folder choice refreshes services without rebuilding controller',
    () async {
      final boundary = _MemoryBoundary(Map.of(MemoryRepository.templates));
      final repository = _MemoryRepository(
        original,
        boundary,
        choice: replacement,
      );
      var coordinatorBuilds = 0;
      final container = ProviderContainer(
        overrides: [
          memoryRepositoryProvider.overrideWithValue(repository),
          memoryUpdateProposalAuthorityProvider.overrideWithValue(
            InMemoryMemoryUpdateProposalAuthority(),
          ),
          memoryMutationCoordinatorProvider.overrideWith((ref) {
            coordinatorBuilds++;
            return MemoryMutationCoordinator(boundary);
          }),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        memoryControllerProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      await container.read(memoryControllerProvider.future);
      final originalEditor = container.read(memoryFileEditorProvider);
      expect(coordinatorBuilds, 1);

      await container.read(memoryControllerProvider.notifier).chooseFolder();
      await container.pump();

      expect(
        container.read(memoryControllerProvider).requireValue?.value,
        'replacement',
      );
      final replacementEditor = container.read(memoryFileEditorProvider);
      expect(replacementEditor, isNot(same(originalEditor)));
      expect(coordinatorBuilds, 2);
    },
  );
}

class _MemoryRepository extends MemoryRepository {
  _MemoryRepository(this.location, this.boundary, {required this.choice})
    : super(Saf());

  MemoryLocation? location;
  final MemoryFileBoundary boundary;
  final MemoryLocation? choice;

  @override
  MemoryLocation? savedLocation() => location;

  @override
  Future<MemoryLocation?> chooseAndInitialize() async {
    if (choice != null) location = choice;
    return choice;
  }

  @override
  MemoryFileBoundary boundaryFor(MemoryLocation location) => boundary;
}

class _MemoryBoundary
    with MemoryBoundaryDelete
    implements MemoryFileBoundary, MemoryFileTransaction {
  _MemoryBoundary(this.files);

  final Map<String, String> files;

  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) => action(this);

  @override
  Future<String> read(String fileName) async => files[fileName]!;

  @override
  Future<void> write(String fileName, String content) async {
    files[fileName] = content;
  }
}
