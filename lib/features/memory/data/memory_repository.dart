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
    'personas.yaml': 'personas: {}\n',
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
    final boundary = boundaryFor(location);
    if (boundary case final MemoryFileStore store) {
      for (final entry in templates.entries) {
        await store.createIfMissing(entry.key, entry.value);
      }
    }
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

  Future<String?> _readIfExists(MemoryFileBoundary boundary, String fileName) =>
      boundary.transaction((files) {
        if (files case final MissingAwareMemoryFileTransaction missingAware) {
          return missingAware.readIfExists(fileName);
        }
        return files.read(fileName).then<String?>((value) => value);
      });

  Future<void> validateSavedLocationAccess(MemoryLocation location) async {
    if (!location.isContentUri) return;
    final grants = await _persistedPermissions();
    final matching = grants.where((grant) => grant.uri == location.value);
    if (!matching.any((grant) => grant.read && grant.write)) {
      throw StateError(
        'The saved memory folder no longer has persisted read and write '
        'access. Re-select the same folder in Memory settings.',
      );
    }
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

class LegacyMemoryMigrationConflict {
  const LegacyMemoryMigrationConflict({
    required this.oldName,
    required this.newName,
  });

  final String oldName;
  final String newName;
}
