import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';
import 'package:saf/saf.dart';
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

  test('subpaths reject symlink traversal at every nested boundary', () async {
    final outside = await Directory.systemTemp.createTemp('mobilka-outside-');
    addTearDown(() => outside.delete(recursive: true));

    Future<bool> linkDirectory(String path, String target) async {
      try {
        await Link(path).create(target);
        return true;
      } on FileSystemException {
        return false;
      }
    }

    final sessions = '${directory.path}${Platform.pathSeparator}sessions';
    if (!await linkDirectory(sessions, outside.path)) return;
    await expectLater(
      store.writeSubPath('sessions/key/session.md', 'unsafe'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await outside.list().isEmpty, isTrue);
    await Link(sessions).delete();

    await Directory(sessions).create();
    final session = '$sessions${Platform.pathSeparator}key';
    await Link(session).create(outside.path);
    await expectLater(
      store.writeSubPath('sessions/key/session.md', 'unsafe'),
      throwsA(isA<FileSystemException>()),
    );
    await Link(session).delete();

    await Directory(session).create();
    final artifacts = '$session${Platform.pathSeparator}artifacts';
    await Link(artifacts).create(outside.path);
    await expectLater(
      store.writeSubPath('sessions/key/artifacts/result.md', 'unsafe'),
      throwsA(isA<FileSystemException>()),
    );
    await Link(artifacts).delete();

    await Directory(artifacts).create();
    final outsideFile = File(
      '${outside.path}${Platform.pathSeparator}outside.md',
    );
    await outsideFile.writeAsString('outside');
    final destination = '$artifacts${Platform.pathSeparator}result.md';
    await Link(destination).create(outsideFile.path);
    await expectLater(
      store.writeSubPath('sessions/key/artifacts/result.md', 'unsafe'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await outsideFile.readAsString(), 'outside');
  });

  test(
    'subpath whitelist permits only exact skills and session layouts',
    () async {
      expect(await store.writeSubPath('skills/runtime.md', 'skill'), isTrue);
      expect(await store.readSubPath('skills/runtime.md'), 'skill');
      expect(await store.listSubPath('skills'), ['runtime.md']);
      for (final path in [
        'sessions/key',
        'skills/nested/runtime.md',
        'skills/../outside.md',
        'sessions/key/other.md',
        'sessions/key/artifacts/nested/file.md',
      ]) {
        expect(await store.writeSubPath(path, 'unsafe'), isFalse, reason: path);
      }
      expect(await store.readSubPath('sessions/key'), isNull);
    },
  );

  test('SAF rejects a bare session path before adapter access', () async {
    final access = _FakeSafMemoryAccess({});
    final safStore = SafMemoryFileStore('content://memory', access);

    expect(await safStore.writeSubPath('sessions/key', 'unsafe'), isFalse);
    expect(await safStore.readSubPath('sessions/key'), isNull);
    expect(access.calls, 0);
  });

  test('revalidates a subpath parent after temporary creation', () async {
    final outside = await Directory.systemTemp.createTemp('mobilka-race-');
    addTearDown(() => outside.delete(recursive: true));
    final sessions = Directory(
      '${directory.path}${Platform.pathSeparator}sessions',
    );
    final session = Directory('${sessions.path}${Platform.pathSeparator}key');
    await session.create(recursive: true);
    var substitutionSupported = true;
    final hooked = PathMemoryFileStore(
      directory.path,
      hooks: PathMemoryFileStoreHooks(
        afterTemporaryCreated: (temporary, destination) async {
          await temporary.delete();
          try {
            await session.rename('${session.path}-removed');
            await Link(session.path).create(outside.path);
          } on FileSystemException {
            substitutionSupported = false;
          }
        },
      ),
    );

    if (!substitutionSupported) return;
    await expectLater(
      hooked.writeSubPath('sessions/key/session.md', 'unsafe'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await outside.list().isEmpty, isTrue);
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

  test('SAF nested write rejects duplicate directory names', () async {
    final access = _AdversarialSafAccess()..duplicateDirectory = 'sessions';
    final safStore = SafMemoryFileStore('content://memory', access);

    await expectLater(
      safStore.writeSubPath('sessions/key/session.md', 'unsafe'),
      throwsStateError,
    );
    expect(access.writes, isEmpty);
  });

  test('SAF nested write rejects a file used as a directory', () async {
    final access = _AdversarialSafAccess()..fileComponent = 'sessions';
    final safStore = SafMemoryFileStore('content://memory', access);

    await expectLater(
      safStore.writeSubPath('sessions/key/session.md', 'unsafe'),
      throwsStateError,
    );
    expect(access.writes, isEmpty);
  });

  test('SAF nested write rejects created child outside parent', () async {
    final access = _AdversarialSafAccess()..returnOutside = true;
    final safStore = SafMemoryFileStore('content://memory', access);

    await expectLater(
      safStore.writeSubPath('sessions/key/session.md', 'unsafe'),
      throwsStateError,
    );
    expect(access.writes, isEmpty);
  });

  for (final operation in ['read', 'list']) {
    for (final position in ['intermediate', 'leaf']) {
      test(
        'SAF $operation rejects mixed-type same-name $position child',
        () async {
          final access = _adversarialNestedTree(
            position: position,
            mixedType: true,
          );
          final safStore = SafMemoryFileStore('content://memory', access);

          await expectLater(
            operation == 'read'
                ? safStore.readSubPath('sessions/key/session.md')
                : safStore.listSubPath('skills'),
            throwsStateError,
          );
        },
      );

      test('SAF $operation rejects duplicate $position children', () async {
        final access = _adversarialNestedTree(
          position: position,
          mixedType: false,
        );
        final safStore = SafMemoryFileStore('content://memory', access);

        await expectLater(
          operation == 'read'
              ? safStore.readSubPath('sessions/key/session.md')
              : safStore.listSubPath('skills'),
          throwsStateError,
        );
      });
    }
  }

  test(
    'SAF nested write uses exact-child resolution for its final leaf',
    () async {
      final access = _adversarialNestedTree(position: 'leaf', mixedType: true);
      final safStore = SafMemoryFileStore('content://memory', access);

      await expectLater(
        safStore.writeSubPath('sessions/key/session.md', 'unsafe'),
        throwsStateError,
      );
      expect(access.writes, isEmpty);
    },
  );

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

  test(
    'configured fake SAF ensure creates personas without legacy files',
    () async {
      final access = _FakeSafMemoryAccess({
        'user.md': 'user',
        'soul.md': 'soul',
        'memory.md': 'memory',
      });
      final store = SafMemoryFileStore('content://memory', access);
      final repository = MemoryRepository(
        Saf(),
        persistedPermissions: () async => const [
          SafPersistedPermission(
            uri: 'content://memory',
            read: true,
            write: true,
            persistedTime: 0,
          ),
        ],
        boundaryFactory: (_) => store,
      );

      await repository.ensureCurrentTemplatesAt(
        const MemoryLocation(value: 'content://memory', isContentUri: true),
      );

      expect(access.files['personas.yaml'], 'personas: {}\n');
      expect(
        access.files.keys,
        unorderedEquals(MemoryRepository.templates.keys),
      );
    },
  );
}

_AdversarialSafAccess _adversarialNestedTree({
  required String position,
  required bool mixedType,
}) {
  const root = 'content://memory';
  final access = _AdversarialSafAccess();
  void add(String parent, String uri, String name, bool isDirectory) {
    access.tree
        .putIfAbsent(parent, () => [])
        .add(SafMemoryDocument(uri: uri, name: name, isDirectory: isDirectory));
    if (isDirectory) access.tree.putIfAbsent(uri, () => []);
  }

  add(root, '$root/sessions', 'sessions', true);
  add('$root/sessions', '$root/sessions/key', 'key', true);
  add(root, '$root/skills', 'skills', true);
  if (position == 'intermediate') {
    add(root, '$root/duplicate-sessions', 'sessions', mixedType ? false : true);
    add(root, '$root/duplicate-skills', 'skills', mixedType ? false : true);
  } else {
    add(
      '$root/sessions/key',
      '$root/sessions/key/session.md',
      'session.md',
      false,
    );
    add(
      '$root/sessions/key',
      '$root/sessions/key/artifacts',
      'artifacts',
      true,
    );
    add(
      '$root/sessions/key',
      '$root/sessions/key/duplicate-${mixedType ? 'mixed' : 'same'}',
      mixedType ? 'session.md' : 'session.md',
      mixedType ? true : false,
    );
    add(
      '$root/sessions/key',
      '$root/sessions/key/duplicate-artifacts',
      'artifacts',
      mixedType ? false : true,
    );
    add('$root/skills', '$root/skills/runtime.md', 'runtime.md', false);
    add(
      '$root/skills',
      '$root/skills/duplicate-runtime.md',
      'runtime.md',
      mixedType ? true : false,
    );
  }
  return access;
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

  @override
  Future<SafMemoryDocument> createDirectory(
    String directoryUri,
    String name,
  ) async => SafMemoryDocument(
    uri: '$directoryUri/$name',
    name: name,
    isDirectory: true,
  );
}

class _AdversarialSafAccess
    with SafAccessDeleteMixin
    implements SafMemoryAccess {
  final Map<String, List<SafMemoryDocument>> tree = {'content://memory': []};
  final List<String> writes = [];
  String? duplicateDirectory;
  String? fileComponent;
  bool returnOutside = false;

  @override
  Future<List<SafMemoryDocument>> list(String directoryUri) async {
    final result = <SafMemoryDocument>[
      ...tree[directoryUri] ?? const <SafMemoryDocument>[],
    ];
    final component = duplicateDirectory ?? fileComponent;
    if (directoryUri == 'content://memory' && component != null) {
      result.add(
        SafMemoryDocument(
          uri: '$directoryUri/$component',
          name: component,
          isDirectory: fileComponent != component,
        ),
      );
      if (duplicateDirectory == component) {
        result.add(
          SafMemoryDocument(
            uri: '$directoryUri/duplicate-$component',
            name: component,
            isDirectory: true,
          ),
        );
      }
    }
    return result;
  }

  @override
  Future<SafMemoryDocument> createDirectory(
    String directoryUri,
    String name,
  ) async {
    final uri = returnOutside
        ? 'content://outside/$name'
        : '$directoryUri/$name';
    final document = SafMemoryDocument(uri: uri, name: name, isDirectory: true);
    if (!returnOutside) {
      tree.putIfAbsent(directoryUri, () => []).add(document);
      tree.putIfAbsent(uri, () => []);
    }
    return document;
  }

  @override
  Future<Uint8List> read(String documentUri) async => Uint8List(0);

  @override
  Future<void> write(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required bool overwrite,
  }) async => writes.add('$directoryUri/$fileName');
}
