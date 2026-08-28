import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';
import 'package:saf/saf.dart';

void main() {
  const authority = 'com.android.externalstorage.documents';

  MemoryRepository repository(List<SafPersistedPermission> grants) =>
      MemoryRepository(Saf(), persistedPermissions: () async => grants);

  SafPersistedPermission grant(
    String uri, {
    bool read = true,
    bool write = true,
  }) => SafPersistedPermission(
    uri: uri,
    read: read,
    write: write,
    persistedTime: 0,
  );

  Future<void> validate(MemoryRepository value, String uri) =>
      value.validateSavedLocationAccess(
        MemoryLocation(value: uri, isContentUri: true),
      );

  test('bare grant restores an existing normalized root URI', () async {
    const bare = 'content://$authority/tree/primary%3AMemory';
    const normalized = '$bare/document/primary%3AMemory';

    await validate(repository([grant(bare)]), normalized);
  });

  test('encoded tree IDs compare by their decoded document ID', () async {
    const saved =
        'content://$authority/tree/primary%3AFolder%20Name/document/'
        'primary%3AFolder%20Name';
    const persisted = 'content://$authority/tree/primary%3AFolder%20Name';

    await validate(repository([grant(persisted)]), saved);
  });

  test(
    'child document, different authority, and different tree do not match',
    () {
      const root = 'content://$authority/tree/primary%3AMemory';
      for (final uri in [
        '$root/document/primary%3AMemory%2Fchild.md',
        'content://other.documents/tree/primary%3AMemory',
        'content://$authority/tree/primary%3AOther',
      ]) {
        expect(
          validate(repository([grant(uri)]), '$root/document/primary%3AMemory'),
          throwsA(isA<StateError>()),
        );
      }
    },
  );

  test('reports missing, read-only, write-only, and malformed distinctly', () {
    const root = 'content://$authority/tree/primary%3AMemory';
    final cases = <(MemoryRepository, String, String)>[
      (repository([]), root, 'no longer has persisted read and write'),
      (repository([grant(root, write: false)]), root, 'read-only'),
      (repository([grant(root, read: false)]), root, 'write-only'),
      (repository([grant(root)]), 'file:///storage/emulated/0', 'unsupported'),
    ];
    for (final (repo, uri, message) in cases) {
      expect(
        validate(repo, uri),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains(message),
          ),
        ),
      );
    }
  });

  test('revocation after a successful check is detected', () async {
    const root = 'content://$authority/tree/primary%3AMemory';
    var grants = [grant(root)];
    final value = MemoryRepository(
      Saf(),
      persistedPermissions: () async => grants,
    );

    await validate(value, '$root/document/primary%3AMemory');
    grants = [];
    await expectLater(validate(value, root), throwsA(isA<StateError>()));
  });

  test(
    'validation preserves the operational URI used for I/O and journals',
    () async {
      const normalized =
          'content://$authority/tree/primary%3AMemory/document/primary%3AMemory';
      final location = MemoryLocation(value: normalized, isContentUri: true);
      final value = repository([
        grant('content://$authority/tree/primary%3AMemory'),
      ]);

      await value.validateSavedLocationAccess(location);

      expect(location.value, normalized);
    },
  );
}
