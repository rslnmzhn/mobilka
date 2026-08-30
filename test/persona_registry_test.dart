import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/application/persona_active_selection_store.dart';
import 'package:mobilka/features/memory/application/persona_registry.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';

void main() {
  test(
    'catalog is canonical metadata and selected prompt loads by id',
    () async {
      final boundary = _Boundary({
        'memory.md': '# Memory\n',
        'personas/reviewer.md': _persona(
          'reviewer',
          'Reviewer',
          'Review carefully.',
        ),
      });
      String? active = 'reviewer';
      final registry = PersonaRegistry(
        mutations: MemoryMutationCoordinator(boundary),
        activeSelection: CallbackPersonaActiveSelectionStore(
          () => active,
          (value) => active = value,
        ),
      );

      final catalog = await registry.refresh();
      expect(catalog.personas.single.id, 'reviewer');
      expect(catalog.personas.single.title, 'Reviewer');
      expect(catalog.personas.single.toJson(), isNot(contains('prompt')));
      expect(await registry.overlayText(), 'Review carefully.\n');
    },
  );

  test('invalid safe files are issues and cannot be selected', () async {
    final boundary = _Boundary({
      'memory.md': '# Memory\n',
      'personas/broken.md': 'not frontmatter',
    });
    final registry = PersonaRegistry(
      mutations: MemoryMutationCoordinator(boundary),
      activeSelection: CallbackPersonaActiveSelectionStore(() => null, (_) {}),
    );
    final catalog = await registry.refresh();
    expect(catalog.personas, isEmpty);
    expect(catalog.issues.single.fileName, 'broken.md');
    await expectLater(registry.switchTo('broken'), throwsStateError);
  });

  test(
    'transient catalog failure throws and never returns stale metadata',
    () async {
      final boundary = _Boundary({
        'memory.md': '# Memory\n',
        'personas/one.md': _persona('one', 'One', 'Prompt'),
      });
      final registry = PersonaRegistry(
        mutations: MemoryMutationCoordinator(boundary),
        activeSelection: CallbackPersonaActiveSelectionStore(
          () => null,
          (_) {},
        ),
      );
      expect((await registry.refresh()).personas, hasLength(1));
      boundary.failList = true;
      await expectLater(registry.refresh(), throwsStateError);
    },
  );

  test('legacy YAML migrates once with byte-exact backup', () async {
    const legacy = 'personas:\n  Reviewer: Review.\n';
    final boundary = _Boundary({
      'memory.md': '# Memory\n',
      'personas.yaml': legacy,
    });
    final registry = PersonaRegistry(
      mutations: MemoryMutationCoordinator(boundary),
      activeSelection: CallbackPersonaActiveSelectionStore(() => null, (_) {}),
    );
    final catalog = await registry.refresh();
    expect(catalog.personas.single.id, 'reviewer');
    expect(boundary.files['personas.yaml.migrated.bak'], legacy);
    expect(boundary.files, isNot(contains('personas.yaml')));
    final after = Map.of(boundary.files);
    await registry.refresh();
    expect(boundary.files, after);
  });
}

String _persona(String id, String title, String prompt) =>
    '---\nid: "$id"\ntitle: "$title"\ndescription: ""\nparams: {}\n---\n$prompt\n';

class _Boundary
    implements
        MemoryFileBoundary,
        MemoryFileTransaction,
        MissingAwareMemoryFileTransaction,
        DeletingMemoryFileTransaction,
        PersonaTreeTransaction {
  _Boundary(this.files);
  final Map<String, String> files;
  bool failList = false;
  @override
  Future<String> read(String fileName) async => files[fileName]!;
  @override
  Future<String?> readIfExists(String fileName) async => files[fileName];
  @override
  Future<void> write(String fileName, String content) async =>
      files[fileName] = content;
  @override
  Future<void> delete(String fileName) async => files.remove(fileName);
  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) => action(this);
  @override
  Future<List<String>> listPersonaFiles() async {
    if (failList) throw StateError('transient list failure');
    final names =
        files.keys
            .where(
              (name) => name.startsWith('personas/') && name.endsWith('.md'),
            )
            .map((name) => name.substring(9))
            .toList()
          ..sort();
    return names;
  }
}
