import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/agents/data/agent_definition_parser.dart';
import 'package:mobilka/features/agents/data/agent_metadata_service.dart';
import 'package:mobilka/features/agents/data/agent_metadata_store.dart';
import 'package:mobilka/features/agents/domain/agent_catalog.dart';

void main() {
  late Directory root;
  late AgentMetadataService service;
  late AgentMetadataStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('agent-metadata-');
    Hive.init(root.path);
    await Hive.openBox<dynamic>('preferences');
    store = const AgentMetadataStore();
    service = AgentMetadataService(store);
  });
  tearDown(() async {
    await Hive.close();
    await root.delete(recursive: true);
  });

  test(
    'metadata store exclusively overlays hidden and favorite state',
    () async {
      final discovery = result();
      var catalog = service.compose(discovery, null);
      await service.setFavorite(catalog, 'writer', true);
      await store.setSelected('writer');
      await service.setHidden(catalog, 'writer', true);

      catalog = service.compose(discovery, store.selectedId);
      final writer = catalog.agents.singleWhere(
        (e) => e.definition.id == 'writer',
      );
      expect(writer.isFavorite, isTrue);
      expect(writer.isHidden, isTrue);
      expect(catalog.selectedId, 'writer');
    },
  );

  test('compose never initializes or repairs selection', () async {
    final catalog = service.compose(result(), 'missing');
    expect(catalog.selectedId, 'missing');
    expect(store.hasSelectedValue, isFalse);
  });
}

AgentDiscoveryResult result() {
  const parser = AgentDefinitionParser();
  AgentDocument parse(String id, String mode) => AgentDocument(
    definition: parser.parse(
      '---\nid: $id\nname: $id\ndescription: Description\nmode: $mode\n---\nPrompt',
    ),
    origin: AgentOrigin.user,
    location: '$id.md',
  );
  return AgentDiscoveryResult(
    documents: [
      parse('general-assistant', 'primary'),
      parse('writer', 'primary'),
    ],
    issues: const [],
  );
}
