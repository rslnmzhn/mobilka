import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/memory/data/context_sources.dart';
import 'package:mobilka/features/memory/data/memory_selection_store.dart';

void main() {
  late Directory hiveDirectory;
  late Directory memoryDirectory;

  setUp(() async {
    hiveDirectory = await Directory.systemTemp.createTemp('mobilka-hive-');
    memoryDirectory = await Directory.systemTemp.createTemp('mobilka-context-');
    Hive.init(hiveDirectory.path);
    await Hive.openBox<dynamic>('preferences');
  });

  tearDown(() async {
    await Hive.close();
    await hiveDirectory.delete(recursive: true);
    await memoryDirectory.delete(recursive: true);
  });

  test('persists selection and reads only selected desktop files', () async {
    final selection = MemorySelectionStore();
    await selection.save({'user_profile.md'});
    await File(
      '${memoryDirectory.path}${Platform.pathSeparator}user_profile.md',
    ).writeAsString('Profile');
    await Hive.box<dynamic>(
      'preferences',
    ).put('memoryLocation', memoryDirectory.path);
    await Hive.box<dynamic>('preferences').put('memoryLocationIsUri', false);
    final source = StoredMemoryContextSource(selection, _SafReader());

    expect(selection.load(), {'user_profile.md'});
    expect(await source.readSelected('user_profile.md'), 'Profile');
    expect(await source.readSelected('memory_log.md'), isNull);
  });

  test('uses SAF adapter for content URI locations', () async {
    final selection = MemorySelectionStore();
    await selection.save({'memory_log.md'});
    await Hive.box<dynamic>(
      'preferences',
    ).put('memoryLocation', 'content://folder');
    await Hive.box<dynamic>('preferences').put('memoryLocationIsUri', true);
    final reader = _SafReader(value: 'Log');
    final source = StoredMemoryContextSource(selection, reader);

    expect(await source.readSelected('memory_log.md'), 'Log');
    expect(reader.lastDirectory, 'content://folder');
  });

  test('loads active agent and tolerates missing asset', () async {
    final source = AssetAgentPromptSource(
      loader: (path) async => 'Agent: $path',
    );
    expect(await source.readActivePrompt(), contains('general-assistant.md'));

    final missing = AssetAgentPromptSource(
      loader: (_) => throw FlutterError('missing'),
    );
    expect(await missing.readActivePrompt(), isNull);
  });
}

class _SafReader implements SafMemoryReader {
  _SafReader({this.value});
  final String? value;
  String? lastDirectory;

  @override
  Future<String?> readChild(String directoryUri, String fileName) async {
    lastDirectory = directoryUri;
    return value;
  }
}
