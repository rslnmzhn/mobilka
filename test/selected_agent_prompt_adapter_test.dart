import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/agents/data/agent_catalog_storage.dart';
import 'package:mobilka/features/agents/data/agent_metadata_service.dart';
import 'package:mobilka/features/agents/data/agent_metadata_store.dart';
import 'package:mobilka/features/agents/data/selected_agent_prompt_adapter.dart';

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
    final storage = AgentCatalogStorage(
      assetLoader: () async => {
        'assets/general.md':
            '---\nid: general-assistant\nname: General\ndescription: Description\n'
            'mode: primary\n---\n# Prompt body',
      },
      directoryProvider: () async =>
          Directory('${root.path}${Platform.pathSeparator}agents'),
    );
    final metadata = const AgentMetadataService(AgentMetadataStore());
    final adapter = SelectedAgentPromptAdapter(storage, metadata);

    expect(await adapter.readActivePrompt(), '# Prompt body');
  });
}
