import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:saf/saf.dart';

import '../../../core/storage/app_boxes.dart';
import '../../../core/logging/app_logger.dart';
import '../application/memory_mutation_coordinator.dart';
import '../application/memory_recovery_journal.dart';
import '../domain/memory_file_names.dart';
import 'memory_file_store.dart';

part 'memory_repository.g.dart';

final memoryLocationRevisionProvider = StateProvider<int>((ref) => 0);

@Riverpod(keepAlive: true)
MemoryRepository memoryRepository(Ref ref) => MemoryRepository(
  Saf(),
  coordinatorFactory: (location, boundary) => MemoryMutationCoordinator(
    boundary,
    journal: HiveMemoryRecoveryJournal(
      memoryRecoveryBox,
      checksum(location.value),
    ),
    logger: ref.read(appLoggerProvider),
  ),
);

typedef MemoryMutationCoordinatorFactory =
    MemoryMutationCoordinator Function(
      MemoryLocation location,
      MemoryFileBoundary boundary,
    );

class MemoryLocation {
  const MemoryLocation({required this.value, required this.isContentUri});
  final String value;
  final bool isContentUri;
}

class MemoryRepository {
  MemoryRepository(
    this._saf, {
    Future<List<SafPersistedPermission>> Function()? persistedPermissions,
    MemoryFileBoundary Function(MemoryLocation location)? boundaryFactory,
    MemoryMutationCoordinatorFactory? coordinatorFactory,
  }) : _persistedPermissions =
           persistedPermissions ?? _saf.persistedPermissions,
       _boundaryFactory = boundaryFactory,
       _coordinatorFactory = coordinatorFactory;
  final Saf _saf;
  final Future<List<SafPersistedPermission>> Function() _persistedPermissions;
  final MemoryFileBoundary Function(MemoryLocation location)? _boundaryFactory;
  final MemoryMutationCoordinatorFactory? _coordinatorFactory;

  static const templates = {
    'user.md':
        '# О пользователе\n\n## Факты\n\n- (пока пусто — агент дополнит)\n',
    'soul.md': '',
    'memory.md':
        '# Память агента\n\nРабочие заметки: находки об инструментах, решения, повторяющиеся паттерны.\n',
  };

  /// Migrates historical aliases without merging content. A modern empty or
  /// untouched template may be replaced; distinct modern user content causes
  /// a non-destructive conflict and leaves both files in place.
  Future<List<LegacyMemoryMigrationConflict>> migrateLegacyFiles() async {
    final location = savedLocation();
    if (location == null) return const [];
    return migrateLegacyFilesAt(location);
  }

  Future<List<LegacyMemoryMigrationConflict>> migrateLegacyFilesAt(
    MemoryLocation location,
  ) async {
    await validateSavedLocationAccess(location);
    await ensureCurrentTemplatesAt(location);
    final boundary = boundaryFor(location);
    final conflicts = <LegacyMemoryMigrationConflict>[];
    final coordinator =
        _coordinatorFactory?.call(location, boundary) ??
        MemoryMutationCoordinator(boundary);
    await coordinator.recover();
    for (final entry in MemoryFiles.flattenedHistoricalAliases) {
      final oldName = entry.key;
      final newName = entry.value;
      final legacyContent = await _readIfExists(boundary, oldName);
      if (legacyContent == null) continue;
      if (legacyContent.trim().isEmpty) continue;
      final backupName = '$oldName.migrated.bak';
      final backup = await _readIfExists(boundary, backupName);
      if (backup != null && backup != legacyContent) {
        conflicts.add(
          LegacyMemoryMigrationConflict(oldName: oldName, newName: newName),
        );
        continue;
      }
      final modernContent = await _readIfExists(boundary, newName);
      final normalizedLegacy = legacyContent.endsWith('\n')
          ? legacyContent
          : '$legacyContent\n';
      final replaceable =
          modernContent == null ||
          modernContent.trim().isEmpty ||
          modernContent == templates[newName] ||
          modernContent == legacyContent ||
          modernContent == normalizedLegacy;
      if (!replaceable) {
        conflicts.add(
          LegacyMemoryMigrationConflict(oldName: oldName, newName: newName),
        );
        continue;
      }
      await coordinator.migrateLegacyAlias(
        legacyName: oldName,
        modernName: newName,
        backupName: backupName,
        content: legacyContent,
        backupAlreadyExists: backup != null,
      );
    }
    return List.unmodifiable(conflicts);
  }

  Future<void> ensureCurrentTemplatesAt(MemoryLocation location) async {
    await validateSavedLocationAccess(location);
    final boundary = boundaryFor(location);
    if (boundary is! MemoryFileStore) return;
    for (final entry in templates.entries) {
      await boundary.createIfMissing(entry.key, entry.value);
    }
  }

  Future<String?> _readIfExists(MemoryFileBoundary boundary, String fileName) =>
      boundary.transaction((files) {
        if (files case final MissingAwareMemoryFileTransaction missingAware) {
          return missingAware.readIfExists(fileName);
        }
        return files.read(fileName).then<String?>((value) => value);
      });

  Future<void> validateSavedLocationAccess(MemoryLocation location) async {
    if (!location.isContentUri) return;
    final savedIdentity = _SafTreeIdentity.tryParse(location.value);
    if (savedIdentity == null) {
      throw StateError(
        'The saved memory folder URI is malformed or unsupported. '
        'Choose the memory folder again in Memory settings.',
      );
    }
    final grants = await _persistedPermissions();
    final matching = grants.where(
      (grant) => _SafTreeIdentity.tryParse(grant.uri) == savedIdentity,
    );
    if (matching.isEmpty) {
      throw StateError(
        'The saved memory folder no longer has persisted read and write '
        'access. Re-select the same folder in Memory settings.',
      );
    }
    if (matching.any((grant) => grant.read && grant.write)) return;
    final hasRead = matching.any((grant) => grant.read);
    final hasWrite = matching.any((grant) => grant.write);
    if (hasRead) {
      throw StateError(
        'The saved memory folder has persisted read-only access. Re-select '
        'the same folder in Memory settings to grant write access.',
      );
    }
    if (hasWrite) {
      throw StateError(
        'The saved memory folder has persisted write-only access. Re-select '
        'the same folder in Memory settings to grant read access.',
      );
    }
    throw StateError(
      'The saved memory folder grant has no persisted read or write access. '
      'Re-select the same folder in Memory settings.',
    );
  }

  Future<void> revalidateCurrentLocationAccess(MemoryLocation location) async {
    final current = savedLocation();
    if (current == null ||
        current.isContentUri != location.isContentUri ||
        current.value != location.value) {
      throw StateError('Configured workspace changed');
    }
    await validateSavedLocationAccess(location);
  }

  MemoryLocation? savedLocation() {
    final value = preferencesBox.get('memoryLocation') as String?;
    if (value == null) return null;
    return MemoryLocation(
      value: value,
      isContentUri:
          preferencesBox.get('memoryLocationIsUri', defaultValue: false)
              as bool,
    );
  }

  MemoryFileBoundary boundaryFor(MemoryLocation location) =>
      _boundaryFactory?.call(location) ??
      (location.isContentUri
          ? SafMemoryFileStore(location.value, SafMemoryAccessAdapter(_saf))
          : PathMemoryFileStore(location.value));

  Future<MemoryLocation?> chooseAndInitialize() async {
    if (Platform.isAndroid) {
      final directory = await _saf.pickDirectory();
      if (directory == null) return null;
      final location = MemoryLocation(value: directory.uri, isContentUri: true);
      await _writeSafTemplates(directory.uri);
      await _save(location);
      return location;
    }

    final path = await getDirectoryPath();
    if (path == null) return null;
    final location = MemoryLocation(value: path, isContentUri: false);
    await _writePathTemplates(path);
    await _save(location);
    return location;
  }

  Future<void> _save(MemoryLocation location) async {
    await preferencesBox.put('memoryLocation', location.value);
    await preferencesBox.put('memoryLocationIsUri', location.isContentUri);
  }

  Future<void> _writeSafTemplates(String uri) async {
    final store = SafMemoryFileStore(uri, SafMemoryAccessAdapter(_saf));
    for (final entry in templates.entries) {
      await store.createIfMissing(entry.key, entry.value);
    }
  }

  Future<void> _writePathTemplates(String path) async {
    final store = PathMemoryFileStore(path);
    for (final entry in templates.entries) {
      await store.createIfMissing(entry.key, entry.value);
    }
  }
}

class _SafTreeIdentity {
  const _SafTreeIdentity(this.scheme, this.authority, this.treeDocumentId);

  final String scheme;
  final String authority;
  final String treeDocumentId;

  static _SafTreeIdentity? tryParse(String value) {
    try {
      final uri = Uri.parse(value);
      if (uri.scheme != 'content' ||
          !uri.hasAuthority ||
          uri.authority.isEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        return null;
      }
      final segments = uri.pathSegments;
      if (segments.length != 2 && segments.length != 4) return null;
      if (segments[0] != 'tree' || segments[1].isEmpty) return null;
      if (segments.length == 4 &&
          (segments[2] != 'document' || segments[3] != segments[1])) {
        return null;
      }
      return _SafTreeIdentity(uri.scheme, uri.authority, segments[1]);
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _SafTreeIdentity &&
      scheme == other.scheme &&
      authority == other.authority &&
      treeDocumentId == other.treeDocumentId;

  @override
  int get hashCode => Object.hash(scheme, authority, treeDocumentId);
}

class LegacyMemoryMigrationConflict {
  const LegacyMemoryMigrationConflict({
    required this.oldName,
    required this.newName,
  });

  final String oldName;
  final String newName;
}
