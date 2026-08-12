import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/agents/application/agents_controller.dart';
import 'package:mobilka/features/agents/data/agent_catalog_storage.dart';
import 'package:mobilka/features/agents/data/agent_definition_parser.dart';
import 'package:mobilka/features/agents/domain/agent_catalog.dart';
import 'package:mobilka/features/agents/domain/agent_definition.dart';

void main() {
  late Directory root;
  late _Storage storage;
  late ProviderContainer container;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('agents-controller-');
    Hive.init(root.path);
    await Hive.openBox<dynamic>('preferences');
    storage = _Storage([
      _document('general-assistant', 'General prompt'),
      _document('writer', 'Writer prompt'),
    ]);
    container = ProviderContainer(
      overrides: [agentCatalogStorageProvider.overrideWithValue(storage)],
    );
  });

  tearDown(() async {
    container.dispose();
    await Hive.close();
    await root.delete(recursive: true);
  });

  test('controller owns selection and refreshes prompt snapshots', () async {
    final controller = container.read(agentsControllerProvider.notifier);
    var catalog = await container.read(agentsControllerProvider.future);
    expect(catalog.selectedId, 'general-assistant');
    expect(
      await container
          .read(selectedAgentPromptAdapterProvider)
          .readActivePrompt(),
      'General prompt',
    );

    await controller.select('writer');
    catalog = await container.read(agentsControllerProvider.future);
    expect(catalog.selectedId, 'writer');
    expect(
      await container
          .read(selectedAgentPromptAdapterProvider)
          .readActivePrompt(),
      'Writer prompt',
    );

    await controller.toggleHidden(catalog.selected!);
    catalog = await container.read(agentsControllerProvider.future);
    expect(catalog.selectedId, isNull);

    await controller.toggleHidden(
      catalog.agents.singleWhere((entry) => entry.definition.id == 'writer'),
    );
    await controller.select('writer');
    await controller.edit('writer', _definition('editor', 'Editor prompt'));
    catalog = await container.read(agentsControllerProvider.future);
    expect(catalog.selectedId, 'editor');
    expect(
      await container
          .read(selectedAgentPromptAdapterProvider)
          .readActivePrompt(),
      'Editor prompt',
    );

    await controller.delete('editor');
    catalog = await container.read(agentsControllerProvider.future);
    expect(catalog.selectedId, isNull);
    expect(
      await container
          .read(selectedAgentPromptAdapterProvider)
          .readActivePrompt(),
      isNull,
    );
  });
}

class _Storage extends AgentCatalogStorage {
  _Storage(this.documents);
  final List<AgentDocument> documents;

  @override
  Future<AgentDiscoveryResult> discover() async => AgentDiscoveryResult(
    documents: List.unmodifiable(documents),
    issues: const [],
  );

  @override
  Future<void> edit(String existingId, AgentDefinition definition) async {
    final index = documents.indexWhere(
      (document) => document.definition.id == existingId,
    );
    documents[index] = AgentDocument(
      definition: definition,
      origin: AgentOrigin.user,
      location: '${definition.id}.md',
    );
  }

  @override
  Future<void> delete(String id) async {
    documents.removeWhere((document) => document.definition.id == id);
  }
}

AgentDocument _document(String id, String prompt) => AgentDocument(
  definition: _definition(id, prompt),
  origin: AgentOrigin.user,
  location: '$id.md',
);

AgentDefinition _definition(
  String id,
  String prompt,
) => const AgentDefinitionParser().parse(
  '---\nid: $id\nname: $id\ndescription: Description\nmode: primary\n---\n$prompt',
);
