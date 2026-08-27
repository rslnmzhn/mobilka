import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/application/memory_recovery_journal.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/domain/memory_file_names.dart';
import 'package:saf/saf.dart';

void main() {
  late Directory directory;
  late MemoryRepository repository;
  late MemoryLocation location;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mobilka-migration-');
    repository = MemoryRepository(Saf());
    location = MemoryLocation(value: directory.path, isContentUri: false);
  });

  tearDown(() => directory.delete(recursive: true));

  Future<void> write(String name, String content) => File(
    '${directory.path}${Platform.pathSeparator}$name',
  ).writeAsString(content);
  Future<String> read(String name) =>
      File('${directory.path}${Platform.pathSeparator}$name').readAsString();

  test('historical aliases are versioned and omit project context', () {
    expect(MemoryFiles.historicalAliases[1]?['user_profile.md'], 'user.md');
    expect(
      MemoryFiles.historicalAliases.values
          .expand((aliases) => aliases.keys)
          .contains('project_context.md'),
      isFalse,
    );
  });

  test('moves legacy content when modern target is missing', () async {
    await write('user_profile.md', 'legacy');
    expect(await repository.migrateLegacyFilesAt(location), isEmpty);
    expect(await read('user.md'), 'legacy\n');
    expect(File('${directory.path}/user_profile.md').existsSync(), isFalse);
    expect(await read('user_profile.md.migrated.bak'), 'legacy');
  });

  test('replaces untouched default template', () async {
    await write('user_profile.md', 'legacy\n');
    await write('user.md', MemoryRepository.templates['user.md']!);
    await repository.migrateLegacyFilesAt(location);
    expect(await read('user.md'), 'legacy\n');
  });

  test('keeps both files and reports custom target conflict', () async {
    await write('user_profile.md', 'legacy\n');
    await write('user.md', 'custom\n');
    final conflicts = await repository.migrateLegacyFilesAt(location);
    expect(conflicts.single.oldName, 'user_profile.md');
    expect(await read('user.md'), 'custom\n');
    expect(await read('user_profile.md'), 'legacy\n');
  });

  test('migration is repeatable and does not merge content', () async {
    await write('memory_log.md', 'legacy notes\n');
    await repository.migrateLegacyFilesAt(location);
    await repository.migrateLegacyFilesAt(location);
    expect(await read('memory.md'), 'legacy notes\n');
  });

  test('backup preserves exact legacy UTF-8 bytes', () async {
    final bytes = utf8.encode('legacy\r\nПривет без LF');
    await File('${directory.path}/user_profile.md').writeAsBytes(bytes);

    await repository.migrateLegacyFilesAt(location);

    expect(
      await File(
        '${directory.path}/user_profile.md.migrated.bak',
      ).readAsBytes(),
      bytes,
    );
    expect(await read('user.md'), 'legacy\r\nПривет без LF\n');
  });

  test('mismatched existing backup is a non-destructive conflict', () async {
    await write('user_profile.md', 'legacy');
    await write('user_profile.md.migrated.bak', 'different');

    final conflicts = await repository.migrateLegacyFilesAt(location);

    expect(conflicts.single.oldName, 'user_profile.md');
    expect(await read('user_profile.md'), 'legacy');
    expect(await read('user_profile.md.migrated.bak'), 'different');
    expect(await read('user.md'), MemoryRepository.templates['user.md']);
  });

  test('rerun recovers interruption after backup write', () async {
    final boundary = _InterruptingBoundary({
      'user_profile.md': 'legacy',
      'user.md': MemoryRepository.templates['user.md']!,
      'memory.md': MemoryRepository.templates['memory.md']!,
    })..failWritesFor.add('user.md');
    final injected = MemoryRepository(Saf(), boundaryFactory: (_) => boundary);

    await expectLater(
      injected.migrateLegacyFilesAt(location),
      throwsA(isA<MemoryMutationException>()),
    );
    boundary.failWritesFor.clear();
    await injected.migrateLegacyFilesAt(location);

    expect(boundary.files['user.md'], 'legacy\n');
    expect(boundary.files['user_profile.md.migrated.bak'], 'legacy');
    expect(boundary.files.containsKey('user_profile.md'), isFalse);
  });

  test('rerun recovers interruption after modern target write', () async {
    final boundary = _InterruptingBoundary({
      'user_profile.md': 'legacy',
      'user.md': MemoryRepository.templates['user.md']!,
      'memory.md': MemoryRepository.templates['memory.md']!,
    })..failDeletesFor.add('user_profile.md');
    final injected = MemoryRepository(Saf(), boundaryFactory: (_) => boundary);

    await expectLater(
      injected.migrateLegacyFilesAt(location),
      throwsA(isA<MemoryMutationException>()),
    );
    boundary.failDeletesFor.clear();
    await injected.migrateLegacyFilesAt(location);

    expect(boundary.files['user.md'], 'legacy\n');
    expect(boundary.files['user_profile.md.migrated.bak'], 'legacy');
    expect(boundary.files.containsKey('user_profile.md'), isFalse);
  });

  test(
    'app restart recovers migration from durable location journal',
    () async {
      final files = <String, String>{
        'user_profile.md': 'legacy',
        'user.md': MemoryRepository.templates['user.md']!,
        'memory.md': MemoryRepository.templates['memory.md']!,
      };
      final durableRecords = <String, Map<String, dynamic>>{};
      var boundary = _InterruptingBoundary(files);

      MemoryRepository createRepository({
        bool interruptJournalRemoval = false,
      }) => MemoryRepository(
        Saf(),
        boundaryFactory: (_) => boundary,
        coordinatorFactory: (selectedLocation, selectedBoundary) =>
            MemoryMutationCoordinator(
              selectedBoundary,
              journal: _DurableTestJournal(
                durableRecords,
                checksum(selectedLocation.value),
                failRemoval: interruptJournalRemoval,
              ),
            ),
      );

      await createRepository(
        interruptJournalRemoval: true,
      ).migrateLegacyFilesAt(location);
      expect(durableRecords, isNotEmpty);

      boundary = _InterruptingBoundary(files);
      await createRepository().migrateLegacyFilesAt(location);

      expect(files['user.md'], 'legacy\n');
      expect(files['user_profile.md.migrated.bak'], 'legacy');
      expect(files.containsKey('user_profile.md'), isFalse);
      expect(durableRecords, isEmpty);
    },
  );

  test(
    'fake SAF migration reruns and deletes only the legacy document',
    () async {
      final access = _FakeSafAccess({
        'user_profile.md': 'legacy',
        'user.md': MemoryRepository.templates['user.md']!,
        'memory.md': MemoryRepository.templates['memory.md']!,
      });
      final store = SafMemoryFileStore('content://memory', access);
      final injected = MemoryRepository(
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
      const safLocation = MemoryLocation(
        value: 'content://memory',
        isContentUri: true,
      );

      await injected.migrateLegacyFilesAt(safLocation);
      await injected.migrateLegacyFilesAt(safLocation);

      expect(access.files['user.md'], 'legacy\n');
      expect(access.files['user_profile.md.migrated.bak'], 'legacy');
      expect(access.files.containsKey('user_profile.md'), isFalse);
      expect(access.deletedNames, ['user_profile.md']);
    },
  );

  test('saved SAF location requires a matching read and write grant', () async {
    final safRepository = MemoryRepository(
      Saf(),
      persistedPermissions: () async => [
        const SafPersistedPermission(
          uri: 'content://other',
          read: true,
          write: true,
          persistedTime: 0,
        ),
        const SafPersistedPermission(
          uri: 'content://memory',
          read: true,
          write: false,
          persistedTime: 0,
        ),
      ],
    );
    const safLocation = MemoryLocation(
      value: 'content://memory',
      isContentUri: true,
    );
    await expectLater(
      safRepository.validateSavedLocationAccess(safLocation),
      throwsA(isA<StateError>()),
    );
  });
}

class _DurableTestJournal implements MemoryRecoveryJournal {
  _DurableTestJournal(
    this._records,
    this._namespace, {
    this.failRemoval = false,
  });

  final Map<String, Map<String, dynamic>> _records;
  final String _namespace;
  final bool failRemoval;

  String _key(String operationId) => '$_namespace:$operationId';

  @override
  Future<List<Map<String, dynamic>>> readAll() async => _records.entries
      .where((entry) => entry.key.startsWith('$_namespace:'))
      .map((entry) => Map<String, dynamic>.of(entry.value))
      .toList();

  @override
  Future<void> write(String operationId, Map<String, dynamic> record) async {
    _records[_key(operationId)] = Map<String, dynamic>.of(record);
  }

  @override
  Future<void> remove(String operationId) async {
    if (failRemoval) throw StateError('simulated process interruption');
    _records.remove(_key(operationId));
  }
}

class _InterruptingBoundary
    implements
        MemoryFileBoundary,
        MemoryFileTransaction,
        MissingAwareMemoryFileTransaction,
        DeletingMemoryFileTransaction {
  _InterruptingBoundary(this.files);
  final Map<String, String> files;
  final Set<String> failWritesFor = {};
  final Set<String> failDeletesFor = {};

  @override
  Future<T> transaction<T>(Future<T> Function(MemoryFileTransaction) action) =>
      action(this);
  @override
  Future<String> read(String fileName) async => files[fileName]!;
  @override
  Future<String?> readIfExists(String fileName) async => files[fileName];
  @override
  Future<void> write(String fileName, String content) async {
    if (failWritesFor.contains(fileName)) throw StateError('interrupted write');
    files[fileName] = content;
  }

  @override
  Future<void> delete(String fileName) async {
    if (failDeletesFor.contains(fileName)) {
      throw StateError('interrupted delete');
    }
    files.remove(fileName);
  }
}

class _FakeSafAccess implements SafMemoryAccess {
  _FakeSafAccess(this.files);
  final Map<String, String> files;
  final List<String> deletedNames = [];

  @override
  Future<List<SafMemoryDocument>> list(String directoryUri) async => [
    for (final name in files.keys)
      SafMemoryDocument(uri: 'doc:$name', name: name, isDirectory: false),
  ];
  @override
  Future<Uint8List> read(String documentUri) async =>
      Uint8List.fromList(utf8.encode(files[documentUri.substring(4)]!));
  @override
  Future<void> write(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required bool overwrite,
  }) async {
    files[fileName] = utf8.decode(content);
  }

  @override
  Future<void> delete(String documentUri) async {
    final name = documentUri.substring(4);
    deletedNames.add(name);
    files.remove(name);
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
