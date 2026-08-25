import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'support/memory_delete_mixins.dart';

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
      store.write('memory.md', first),
      otherStore.write('memory.md', second),
    ]);

    final result = await store.read('memory.md');
    expect(result == first || result == second, isTrue);
  });

  test('rejects traversal and non-markdown names', () async {
    expect(() => store.write('../secret.md', 'unsafe'), throwsFormatException);
    expect(() => store.write('secret.txt', 'unsafe'), throwsFormatException);
  });

  test('reads the last serialized write', () async {
    await store.write('user.md', 'first');
    await store.write('user.md', 'second');
    expect(await store.read('user.md'), 'second');
  });

  test('createIfMissing preserves existing user content', () async {
    await store.createIfMissing('user.md', 'first');
    await store.createIfMissing('user.md', 'second');
    expect(await store.read('user.md'), 'first');
  });

  test('rejects a symbolic-link target when supported', () async {
    final outside = File(
      '${directory.parent.path}${Platform.pathSeparator}mobilka-outside.md',
    );
    await outside.writeAsString('outside');
    final link = Link('${directory.path}${Platform.pathSeparator}memory.md');
    try {
      await link.create(outside.path);
    } on FileSystemException {
      await outside.delete();
      return;
    }
    expect(
      () => store.write('memory.md', 'unsafe'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await outside.readAsString(), 'outside');
    await outside.delete();
  });

  test('atomic replacement defeats target substitution before rename', () async {
    final outside = File(
      '${directory.parent.path}${Platform.pathSeparator}mobilka-race-outside.md',
    );
    await outside.writeAsString('outside');
    final target = File('${directory.path}${Platform.pathSeparator}memory.md');
    await target.writeAsString('inside');
    final link = Link(target.path);
    try {
      await target.delete();
      await link.create(outside.path);
    } on FileSystemException {
      if (await link.exists()) await link.delete();
      await outside.delete();
      return;
    }

    await expectLater(
      store.write('memory.md', 'unsafe'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await outside.readAsString(), 'outside');
    await link.delete();
    await outside.delete();
  });

  test(
    'SAF store reads exact children and overwrites through adapter',
    () async {
      final access = _FakeSafMemoryAccess({
        'user.md': 'old',
        'user.md.bak': 'backup',
      });
      final safStore = SafMemoryFileStore('content://memory', access);

      expect(await safStore.read('user.md'), 'old');
      await safStore.write('user.md', 'new');

      expect(await safStore.read('user.md'), 'new');
      expect(access.lastOverwrite, isTrue);
    },
  );

  test('SAF store rejects traversal before accessing the adapter', () async {
    final access = _FakeSafMemoryAccess({});
    final safStore = SafMemoryFileStore('content://memory', access);

    expect(() => safStore.write('../user.md', 'unsafe'), throwsFormatException);
    expect(access.calls, 0);
  });

  test('SAF snapshot rejects duplicate file names', () async {
    final access = _FakeSafMemoryAccess({'user.md': 'profile'})
      ..duplicateName = 'user.md';
    final safStore = SafMemoryFileStore('content://memory', access);

    await expectLater(
      safStore.transaction((files) => files.read('user.md')),
      throwsStateError,
    );
  });

  test('rejects malformed UTF-8 and oversized reads', () async {
    final malformed = _FakeSafMemoryAccess({'user.md': 'profile'})
      ..rawBytes = Uint8List.fromList([0xC3, 0x28]);
    await expectLater(
      SafMemoryFileStore('content://memory', malformed).read('user.md'),
      throwsFormatException,
    );
    malformed.rawBytes = Uint8List(maxMemoryFileBytes + 1);
    await expectLater(
      SafMemoryFileStore('content://memory', malformed).read('user.md'),
      throwsFormatException,
    );
  });

  test('desktop transaction keeps reads and writes on one adapter', () async {
    await store.createIfMissing('user.md', 'before');
    await store.transaction((files) async {
      expect(await files.read('user.md'), 'before');
      await files.write('user.md', 'after');
    });
    expect(await store.read('user.md'), 'after');
  });

  test(
    'SAF create preserves existing files and creates missing files',
    () async {
      final access = _FakeSafMemoryAccess({'user.md': 'existing'});
      final safStore = SafMemoryFileStore('content://memory', access);
      await safStore.createIfMissing('user.md', 'replacement');
      await safStore.createIfMissing('memory.md', 'created');

      expect(access.files['user.md'], 'existing');
      expect(access.files['memory.md'], 'created');
      expect(access.lastOverwrite, isFalse);
    },
  );
}

class _FakeSafMemoryAccess
    with SafAccessDeleteMixin
    implements SafMemoryAccess {
  _FakeSafMemoryAccess(this.files);

  final Map<String, String> files;
  bool? lastOverwrite;
  int calls = 0;
  String? duplicateName;
  Uint8List? rawBytes;

  @override
  Future<List<SafMemoryDocument>> list(String directoryUri) async {
    calls++;
    final documents = files.keys
        .map(
          (name) => SafMemoryDocument(
            uri: '$directoryUri/$name',
            name: name,
            isDirectory: false,
          ),
        )
        .toList();
    if (duplicateName case final name?) {
      documents.add(
        SafMemoryDocument(
          uri: '$directoryUri/duplicate-$name',
          name: name,
          isDirectory: false,
        ),
      );
    }
    return documents;
  }

  @override
  Future<Uint8List> read(String documentUri) async {
    calls++;
    final fileName = documentUri.substring(documentUri.lastIndexOf('/') + 1);
    return rawBytes ?? Uint8List.fromList(files[fileName]!.codeUnits);
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
