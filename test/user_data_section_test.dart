import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/core/storage/app_boxes.dart';
import 'package:mobilka/features/artifacts/data/artifact_store.dart';
import 'package:mobilka/features/artifacts/data/local_artifact_files.dart';
import 'package:mobilka/features/settings/presentation/user_data_section.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory filesDir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mobilka-user-data');
    filesDir = Directory(p.join(root.path, 'files'));
    await filesDir.create();
    Hive.init(p.join(root.path, 'hive'));
    await Hive.openBox<dynamic>('conversations');
    await Hive.openBox<dynamic>('artifacts');
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk('conversations');
    await Hive.deleteBoxFromDisk('artifacts');
    await Hive.close();
    await root.delete(recursive: true);
  });

  Future<void> seed() async {
    await conversationsBox.put('conversation', {
      'id': 'conversation',
      'role': 'user',
      'title': 'Chat',
      'modelId': 'model',
      'content': '',
      'createdAt': '2026-01-01T00:00:00.000Z',
      'status': 'complete',
    });
    await artifactsBox.put('artifact', {
      'id': 'artifact',
      'title': 'Doc',
      'content': '# Doc',
      'createdAt': '2026-01-01T00:00:00.000Z',
      'updatedAt': '2026-01-01T00:00:00.000Z',
    });
    await File(p.join(filesDir.path, 'artifact.md')).writeAsString('# Doc');
  }

  test('collectExportData snapshots conversations and artifacts', () async {
    await seed();

    final data = collectExportData();

    expect(data['conversations'], hasLength(1));
    expect(data['artifacts'], hasLength(1));
    final encoded = const JsonEncoder.withIndent('  ').convert(data);
    expect(encoded, contains('"title": "Chat"'));
    expect(encoded, contains('"title": "Doc"'));
  });

  test(
    'deleteAllLocalData wipes records and generated files, keeps memory',
    () async {
      await seed();
      final container = ProviderContainer(
        overrides: [
          localArtifactFilesProvider.overrideWithValue(
            LocalArtifactFiles(baseDirectory: () => filesDir),
          ),
        ],
      );
      addTearDown(container.dispose);

      await deleteAllLocalData(
        (id) => container.read(localArtifactFilesProvider).delete(id),
      );

      expect(conversationsBox.isEmpty, isTrue);
      expect(artifactsBox.isEmpty, isTrue);
      expect(filesDir.listSync().whereType<File>(), isEmpty);
    },
  );
}
