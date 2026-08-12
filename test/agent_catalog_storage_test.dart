import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/agents/data/agent_catalog_storage.dart';
import 'package:mobilka/features/agents/data/agent_definition_parser.dart';
import 'package:mobilka/features/agents/domain/agent_catalog.dart';
import 'package:mobilka/features/agents/domain/agent_definition.dart';

void main() {
  late Directory root;
  late Directory agentsDirectory;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mobilka-agent-storage-');
    agentsDirectory = Directory('${root.path}${Platform.pathSeparator}agents');
  });

  tearDown(() => root.delete(recursive: true));

  AgentCatalogStorage storage({Map<String, String>? assets}) =>
      AgentCatalogStorage(
        assetLoader: () async => assets ?? {'assets/default.md': document()},
        directoryProvider: () async => agentsDirectory,
      );

  test(
    'discovers bundled and user definitions and reports duplicates',
    () async {
      await agentsDirectory.create();
      await File(
        '${agentsDirectory.path}${Platform.pathSeparator}writer.md',
      ).writeAsString(document(id: 'writer', name: 'Writer'));
      await File(
        '${agentsDirectory.path}${Platform.pathSeparator}duplicate.md',
      ).writeAsString(document());

      final result = await storage().discover();

      expect(result.documents.map((agent) => agent.definition.id), {
        'general-assistant',
        'writer',
      });
      expect(result.issues.single.message, contains('Duplicate agent id'));
    },
  );

  test('preflights oversized discovery files before bounded parsing', () async {
    await agentsDirectory.create();
    final oversized = File(
      '${agentsDirectory.path}${Platform.pathSeparator}large.md',
    );
    await oversized.writeAsBytes(
      List.filled(AgentDefinitionParser.maxDocumentBytes + 1, 97),
    );

    final result = await storage().discover();

    expect(result.documents, hasLength(1));
    expect(result.issues.single.message, contains('too large'));
  });

  test('creates, atomically edits, and deletes canonical user files', () async {
    final subject = storage();
    await subject.create(definition(id: 'writer', name: 'Writer'));
    final created = File(
      '${agentsDirectory.path}${Platform.pathSeparator}writer.md',
    );
    expect(await created.readAsString(), startsWith('---\nid: "writer"'));
    expect(
      await agentsDirectory
          .list()
          .where((entity) => entity.path.endsWith('.tmp'))
          .toList(),
      isEmpty,
    );

    await subject.edit('writer', definition(id: 'writer', name: 'Rewritten'));
    expect(await created.readAsString(), contains('name: "Rewritten"'));

    await subject.edit('writer', definition(id: 'editor', name: 'Editor'));
    expect(await created.exists(), isFalse);
    expect((await subject.discover()).documents.map((e) => e.definition.id), {
      'general-assistant',
      'editor',
    });
    await subject.delete('editor');
    expect(
      (await subject.discover()).documents.single.origin,
      AgentOrigin.bundled,
    );
  });

  test('rejects symlink destinations and leaves no temporary file', () async {
    if (Platform.isWindows) return;
    await agentsDirectory.create();
    final target = File('${root.path}${Platform.pathSeparator}target.md');
    await target.writeAsString('unchanged');
    await Link(
      '${agentsDirectory.path}${Platform.pathSeparator}writer.md',
    ).create(target.path);

    await expectLater(
      storage().create(definition(id: 'writer')),
      throwsStateError,
    );

    expect(await target.readAsString(), 'unchanged');
    expect(
      await agentsDirectory
          .list()
          .where((entity) => entity.path.endsWith('.tmp'))
          .toList(),
      isEmpty,
    );
  });

  test('rejects non-file destinations and leaves no temporary file', () async {
    await agentsDirectory.create();
    await Directory(
      '${agentsDirectory.path}${Platform.pathSeparator}writer.md',
    ).create();

    await expectLater(
      storage().create(definition(id: 'writer')),
      throwsStateError,
    );

    expect(
      await agentsDirectory
          .list()
          .where((entity) => entity.path.endsWith('.tmp'))
          .toList(),
      isEmpty,
    );
  });
}

AgentDefinition definition({
  String id = 'agent',
  String name = 'Agent',
  AgentMode mode = AgentMode.primary,
  String prompt = 'Prompt body',
}) => AgentDefinition(
  id: id,
  name: name,
  description: 'Description',
  mode: mode,
  prompt: prompt,
);

String document({
  String id = 'general-assistant',
  String name = 'General Assistant',
}) =>
    '---\nid: $id\nname: "$name"\ndescription: "Description"\n'
    'mode: primary\n---\nPrompt body';
