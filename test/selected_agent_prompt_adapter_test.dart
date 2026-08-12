import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/agents/data/selected_agent_prompt_adapter.dart';
import 'package:mobilka/features/agents/data/agent_definition_parser.dart';
import 'package:mobilka/features/agents/domain/agent_catalog.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('selected-prompt-');
    Hive.init(root.path);
    await Hive.openBox<dynamic>('preferences');
  });
  tearDown(() async {
    await Hive.close();
    await root.delete(recursive: true);
  });

  test('returns only the selected parsed prompt body', () async {
    final definition = const AgentDefinitionParser().parse(
      '---\nid: general-assistant\nname: General\ndescription: Description\n'
      'mode: primary\n---\n# Prompt body',
    );
    final catalog = AgentCatalog(
      agents: [
        AgentCatalogEntry(
          definition: definition,
          origin: AgentOrigin.bundled,
          location: 'asset',
          isHidden: false,
          isFavorite: false,
        ),
      ],
      issues: const [],
      selectedId: 'general-assistant',
    );
    final adapter = SelectedAgentPromptAdapter(Future.value(catalog));

    expect(await adapter.readActivePrompt(), '# Prompt body');
  });
}
