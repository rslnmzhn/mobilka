import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';

void main() {
  late Directory directory;
  late PathMemoryFileStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mobilka-memory-test-');
    store = PathMemoryFileStore(directory.path);
  });

  tearDown(() => directory.delete(recursive: true));

  test('serializes concurrent writes across store instances', () async {
    final first = 'A' * 10000;
    final second = 'B' * 10000;
    final otherStore = PathMemoryFileStore(directory.path);
    await Future.wait([
      store.write('memory_log.md', first),
      otherStore.write('memory_log.md', second),
    ]);

    final result = await store.read('memory_log.md');
    expect(result == first || result == second, isTrue);
  });

  test('rejects traversal and non-markdown names', () async {
    expect(() => store.write('../secret.md', 'unsafe'), throwsFormatException);
    expect(() => store.write('secret.txt', 'unsafe'), throwsFormatException);
  });

  test('reads the last serialized write', () async {
    await store.write('user_profile.md', 'first');
    await store.write('user_profile.md', 'second');
    expect(await store.read('user_profile.md'), 'second');
  });

  test('createIfMissing preserves existing user content', () async {
    await store.createIfMissing('user_profile.md', 'first');
    await store.createIfMissing('user_profile.md', 'second');
    expect(await store.read('user_profile.md'), 'first');
  });

  test('rejects a symbolic-link target when supported', () async {
    final outside = File(
      '${directory.parent.path}${Platform.pathSeparator}mobilka-outside.md',
    );
    await outside.writeAsString('outside');
    final link = Link(
      '${directory.path}${Platform.pathSeparator}memory_log.md',
    );
    try {
      await link.create(outside.path);
    } on FileSystemException {
      await outside.delete();
      return;
    }
    expect(
      () => store.write('memory_log.md', 'unsafe'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await outside.readAsString(), 'outside');
    await outside.delete();
  });

  test(
    'SAF store reads exact children and overwrites through adapter',
    () async {
      final access = _FakeSafMemoryAccess({
        'user_profile.md': 'old',
        'user_profile.md.bak': 'backup',
      });
      final safStore = SafMemoryFileStore('content://memory', access);

      expect(await safStore.read('user_profile.md'), 'old');
      await safStore.write('user_profile.md', 'new');

      expect(await safStore.read('user_profile.md'), 'new');
      expect(access.lastOverwrite, isTrue);
    },
  );

  test('SAF store rejects traversal before accessing the adapter', () async {
    final access = _FakeSafMemoryAccess({});
    final safStore = SafMemoryFileStore('content://memory', access);

    expect(
      () => safStore.write('../user_profile.md', 'unsafe'),
      throwsFormatException,
    );
    expect(access.calls, 0);
  });
}

class _FakeSafMemoryAccess implements SafMemoryAccess {
  _FakeSafMemoryAccess(this.files);

  final Map<String, String> files;
  bool? lastOverwrite;
  int calls = 0;

  @override
  Future<List<SafMemoryDocument>> list(String directoryUri) async {
    calls++;
    return files.keys
        .map(
          (name) => SafMemoryDocument(
            uri: '$directoryUri/$name',
            name: name,
            isDirectory: false,
          ),
        )
        .toList();
  }

  @override
  Future<Uint8List> read(String documentUri) async {
    calls++;
    final fileName = documentUri.substring(documentUri.lastIndexOf('/') + 1);
    return Uint8List.fromList(files[fileName]!.codeUnits);
  }

  @override
  Future<void> write(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required bool overwrite,
  }) async {
    calls++;
    lastOverwrite = overwrite;
    files[fileName] = String.fromCharCodes(content);
  }
}
