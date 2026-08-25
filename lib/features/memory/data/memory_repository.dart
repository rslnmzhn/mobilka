import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:saf/saf.dart';

import '../../../core/storage/app_boxes.dart';
import '../domain/memory_file_names.dart';
import 'memory_file_store.dart';

part 'memory_repository.g.dart';

@Riverpod(keepAlive: true)
MemoryRepository memoryRepository(Ref ref) => MemoryRepository(Saf());

class MemoryLocation {
  const MemoryLocation({required this.value, required this.isContentUri});
  final String value;
  final bool isContentUri;
}

class MemoryRepository {
  MemoryRepository(this._saf);
  final Saf _saf;

  static const templates = {
    'user.md':
        '# О пользователе\n\n## Факты\n\n- (пока пусто — агент дополнит)\n',
    'soul.md': '',
    'memory.md':
        '# Память агента\n\nРабочие заметки: находки об инструментах, решения, повторяющиеся паттерны.\n',
  };

  /// One-shot rename of legacy files to the Memory 2.0 scheme.
  /// Idempotent: skips when the old file is absent or the target exists.
  /// Keeps a `.migrated.bak` copy of the original next to the new file.
  Future<void> migrateLegacyFiles() async {
    final location = savedLocation();
    if (location == null) return;
    final boundary = boundaryFor(location);
    for (final entry in MemoryFiles.legacyRenames.entries) {
      final oldName = entry.key;
      final newName = entry.value;
      String? legacyContent;
      try {
        legacyContent = await boundary.read(oldName);
      } on Object {
        continue; // nothing to migrate for this pair
      }
      if (legacyContent.trim().isEmpty) continue;
      if (!legacyContent.endsWith('\n')) legacyContent += '\n';
      var modernContent = '';
      try {
        modernContent = await boundary.read(newName);
      } on Object {
        // target missing — will be created below
      }
      if (modernContent.trim().isNotEmpty) {
        // Target already has content: merge legacy under a section header
        // instead of overwriting user data.
        modernContent =
            '${modernContent.trimRight()}\n\n'
            '## Перенесено из $oldName\n\n'
            '${legacyContent.trim()}\n';
        await boundary.write(newName, modernContent);
      } else {
        await boundary.write(newName, legacyContent);
      }
      await boundary.write('$oldName.migrated.bak', legacyContent);
      await boundary.delete(oldName);
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
      location.isContentUri
      ? SafMemoryFileStore(location.value, SafMemoryAccessAdapter(_saf))
      : PathMemoryFileStore(location.value);

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
