import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/memory/data/context_sources.dart';

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

  test('reads desktop memory files without owning selection', () async {
    await File(
      '${memoryDirectory.path}${Platform.pathSeparator}user_profile.md',
    ).writeAsString('Profile');
    await Hive.box<dynamic>(
      'preferences',
    ).put('memoryLocation', memoryDirectory.path);
    await Hive.box<dynamic>('preferences').put('memoryLocationIsUri', false);
    final source = StoredMemoryContextSource(_SafReader());

    expect(await source.read('user_profile.md'), 'Profile');
    expect(await source.read('memory_log.md'), isNull);
  });

  test('uses SAF adapter for content URI locations', () async {
    await Hive.box<dynamic>(
      'preferences',
    ).put('memoryLocation', 'content://folder');
    await Hive.box<dynamic>('preferences').put('memoryLocationIsUri', true);
    final reader = _SafReader(value: 'Log');
    final source = StoredMemoryContextSource(reader);

    expect(await source.read('memory_log.md'), 'Log');
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
