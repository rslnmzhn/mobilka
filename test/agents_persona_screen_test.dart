import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/agents/application/agents_controller.dart';
import 'package:mobilka/features/agents/domain/agent_catalog.dart';
import 'package:mobilka/features/agents/presentation/agents_screen.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/application/memory_file_editor.dart';
import 'package:mobilka/features/memory/application/persona_active_selection_store.dart';
import 'package:mobilka/features/memory/application/persona_registry.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';

void main() {
  for (final size in const [Size(320, 720), Size(1280, 800)]) {
    testWidgets('canonical persona controls fit ${size.width}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? active;
      final boundary = _Boundary({
        'memory.md': '# Memory\n',
        'personas/reviewer.md': _persona('reviewer', 'Reviewer'),
        'personas/broken.md': 'broken',
      });
      final registry = PersonaRegistry(
        mutations: MemoryMutationCoordinator(boundary),
        activeSelection: CallbackPersonaActiveSelectionStore(
          () => active,
          (value) => active = value,
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            agentsControllerProvider.overrideWith(_EmptyAgents.new),
            personaRegistryProvider.overrideWithValue(registry),
            activePersonaControllerProvider.overrideWith(
              _TestActivePersonaController.new,
            ),
            memoryFileEditorProvider.overrideWithValue(null),
          ],
          child: const MaterialApp(home: AgentsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('persona-reviewer')), findsOneWidget);
      expect(find.byKey(const Key('persona-edit-reviewer')), findsOneWidget);
      expect(find.byKey(const Key('persona-delete-reviewer')), findsOneWidget);
      expect(find.text('broken.md'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

class _TestActivePersonaController extends ActivePersonaController {
  @override
  String? build() => null;
}

String _persona(String id, String title) =>
    '---\nid: "$id"\ntitle: "$title"\ndescription: ""\nparams: {}\n---\nPrompt\n';

class _EmptyAgents extends AgentsController {
  @override
  Future<AgentCatalog> build() async =>
      const AgentCatalog(agents: [], issues: [], selectedId: null);
}

class _Boundary
    implements
        MemoryFileBoundary,
        MemoryFileTransaction,
        MissingAwareMemoryFileTransaction,
        DeletingMemoryFileTransaction,
        PersonaTreeTransaction {
  _Boundary(this.files);
  final Map<String, String> files;
  @override
  Future<String> read(String name) async => files[name]!;
  @override
  Future<String?> readIfExists(String name) async => files[name];
  @override
  Future<void> write(String name, String value) async => files[name] = value;
  @override
  Future<void> delete(String name) async => files.remove(name);
  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) => action(this);
  @override
  Future<List<String>> listPersonaFiles() async =>
      (files.keys
          .where((name) => name.startsWith('personas/'))
          .map((name) => name.substring(9))
          .toList()
        ..sort());
}
