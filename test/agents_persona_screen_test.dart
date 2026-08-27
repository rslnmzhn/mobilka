import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/agents/application/agents_controller.dart';
import 'package:mobilka/features/agents/data/agent_definition_parser.dart';
import 'package:mobilka/features/agents/domain/agent_catalog.dart';
import 'package:mobilka/features/agents/presentation/agents_screen.dart';
import 'package:mobilka/features/memory/application/memory_file_editor.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/application/persona_registry.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';
import 'package:mobilka/features/memory/presentation/memory_editor_sheet.dart';

void main() {
  for (final size in const [Size(320, 720), Size(1280, 800)]) {
    testWidgets(
      'persona section renders, activates, clears, and edits at ${size.width}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? active;
        final registry = PersonaRegistry(
          readYaml: () async => 'personas:\n  reviewer: Review carefully.\n',
          readActive: () => active,
          writeActive: (value) => active = value,
        );
        final boundary = _Boundary({
          'personas.yaml': 'personas:\n  reviewer: Review carefully.\n',
        });
        final editor = MemoryFileEditor(
          boundary,
          MemoryMutationCoordinator(boundary),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              agentsControllerProvider.overrideWith(_AgentsController.new),
              personaRegistryProvider.overrideWithValue(registry),
              memoryFileEditorProvider.overrideWithValue(editor),
            ],
            child: const MaterialApp(home: AgentsScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('persona-reviewer')), findsOneWidget);
        expect(find.byKey(const Key('persona-clear')), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('persona-reviewer')));
        await tester.pumpAndSettle();
        expect(active, 'reviewer');
        expect(
          tester
              .widget<ChoiceChip>(find.byKey(const Key('persona-reviewer')))
              .selected,
          isTrue,
        );

        await tester.tap(find.byKey(const Key('persona-clear')));
        await tester.pumpAndSettle();
        expect(active, isNull);

        await tester.tap(find.byKey(const Key('persona-edit')));
        await tester.pumpAndSettle();
        expect(find.byType(MemoryEditorSheet), findsOneWidget);
        expect(find.byKey(const Key('memory-editor-content')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('personas remain visible when the agent catalog is empty', (
    tester,
  ) async {
    final registry = PersonaRegistry(
      readYaml: () async => 'personas:\n  solo: Independent.\n',
      readActive: () => null,
      writeActive: (_) {},
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          agentsControllerProvider.overrideWith(_EmptyAgentsController.new),
          personaRegistryProvider.overrideWithValue(registry),
          memoryFileEditorProvider.overrideWithValue(null),
        ],
        child: const MaterialApp(home: AgentsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('persona-solo')), findsOneWidget);
    expect(find.text('agents.empty'), findsOneWidget);
  });

  testWidgets('mounted persona section reacts to registry provider changes', (
    tester,
  ) async {
    final source = StateProvider<PersonaRegistry>(
      (ref) => PersonaRegistry(
        readYaml: () async => 'personas:\n  first: One.\n',
        readActive: () => null,
        writeActive: (_) {},
      ),
    );
    final container = ProviderContainer(
      overrides: [
        agentsControllerProvider.overrideWith(_AgentsController.new),
        personaRegistryProvider.overrideWith((ref) => ref.watch(source)),
        memoryFileEditorProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AgentsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('persona-first')), findsOneWidget);

    container.read(source.notifier).state = PersonaRegistry(
      readYaml: () async => 'personas:\n  second: Two.\n',
      readActive: () => null,
      writeActive: (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('persona-first')), findsNothing);
    expect(find.byKey(const Key('persona-second')), findsOneWidget);
  });

  testWidgets('external switch on same registry updates mounted section', (
    tester,
  ) async {
    String? active;
    final registry = PersonaRegistry(
      readYaml: () async => 'personas:\n  reviewer: Review carefully.\n',
      readActive: () => active,
      writeActive: (value) => active = value,
    );
    final container = ProviderContainer(
      overrides: [
        agentsControllerProvider.overrideWith(_AgentsController.new),
        personaRegistryProvider.overrideWithValue(registry),
        memoryFileEditorProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AgentsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await container.read(personaRegistryAdapterProvider).switchTo('reviewer');
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('persona-reviewer')))
          .selected,
      isTrue,
    );
    expect(find.textContaining('reviewer'), findsWidgets);
  });

  test('persona state rebuilds for memory location revision', () async {
    final revision = StateProvider<int>((ref) => 0);
    final container = ProviderContainer(
      overrides: [
        memoryLocationRevisionProvider.overrideWith(
          (ref) => ref.watch(revision),
        ),
        personaRegistryProvider.overrideWith((ref) {
          final current = ref.watch(memoryLocationRevisionProvider);
          return PersonaRegistry(
            readYaml: () async => 'personas:\n  location$current: Active.\n',
            readActive: () => null,
            writeActive: (_) {},
          );
        }),
      ],
    );
    addTearDown(container.dispose);

    expect(
      (await container.read(
        personaRegistryStateProvider.future,
      )).entries.single.name,
      'location0',
    );
    container.read(revision.notifier).state++;
    expect(
      (await container.read(
        personaRegistryStateProvider.future,
      )).entries.single.name,
      'location1',
    );
  });
}

class _AgentsController extends AgentsController {
  @override
  Future<AgentCatalog> build() async => AgentCatalog(
    agents: [
      AgentCatalogEntry(
        definition: const AgentDefinitionParser().parse(
          '---\nid: general\nname: General\ndescription: General\nmode: primary\n---\nPrompt',
        ),
        origin: AgentOrigin.bundled,
        location: 'general.md',
        isHidden: false,
        isFavorite: false,
      ),
    ],
    issues: const [],
    selectedId: 'general',
  );
}

class _EmptyAgentsController extends AgentsController {
  @override
  Future<AgentCatalog> build() async =>
      const AgentCatalog(agents: [], issues: [], selectedId: null);
}

class _Boundary implements MemoryFileBoundary, MemoryFileTransaction {
  _Boundary(this.files);
  final Map<String, String> files;

  @override
  Future<void> delete(String fileName) async => files.remove(fileName);
  @override
  Future<String> read(String fileName) async => files[fileName]!;
  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) => action(this);
  @override
  Future<void> write(String fileName, String content) async =>
      files[fileName] = content;
}
