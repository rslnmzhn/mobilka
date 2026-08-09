import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:saf/saf.dart';

import '../../../core/storage/app_boxes.dart';

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
    'user_profile.md':
        '# User Profile\n\nAdd stable facts and preferences here.\n',
    'project_context.md':
        '# Project Context\n\nActive projects and working context.\n',
    'system_instructions.md':
        '# System Instructions\n\nUser-controlled instructions for agents.\n',
    'memory_log.md': '# Memory Log\n\nChronological memory updates.\n',
  };

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
    for (final entry in templates.entries) {
      try {
        await _saf.writeFileBytes(
          uri,
          entry.key,
          'text/markdown',
          Uint8List.fromList(utf8.encode(entry.value)),
        );
      } on SafAlreadyExistsException {
        // Existing user-owned memory is never overwritten.
      }
    }
  }

  Future<void> _writePathTemplates(String path) async {
    final directory = Directory(path);
    final canonicalDirectory = await directory.resolveSymbolicLinks();
    for (final entry in templates.entries) {
      final file = File(
        '$canonicalDirectory${Platform.pathSeparator}${entry.key}',
      );
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        final temporary = File(
          '${file.path}.mobilka-${DateTime.now().microsecondsSinceEpoch}.tmp',
        );
        await temporary.writeAsString(entry.value, flush: true);
        if (await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          await temporary.rename(file.path);
        } else {
          await temporary.delete();
        }
      }
    }
  }
}
