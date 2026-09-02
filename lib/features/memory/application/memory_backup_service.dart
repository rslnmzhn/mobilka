import 'dart:convert';

import '../data/memory_file_store.dart';
import '../domain/memory_file_names.dart';
import '../domain/persona.dart';
import 'memory_backup_codec.dart';
import 'memory_mutation_coordinator.dart';
import 'legacy_persona_migrator.dart';

class MemoryBackupService {
  MemoryBackupService(
    MemoryFileBoundary boundary,
    this._mutations, {
    MemoryBackupCodec codec = const MemoryBackupCodec(),
    DateTime Function()? now,
    Future<void> Function()? ready,
    Future<void> Function(Set<String> ids)? personasDeleted,
  }) : _codec = codec,
       _now = now ?? DateTime.now,
       _ready = ready ?? (() => Future<void>.value()),
       _personasDeleted = personasDeleted ?? ((_) async {});

  static const maxFileBytes = MemoryBackupCodec.maxFileBytes;
  static const maxDocumentBytes = MemoryBackupCodec.maxDocumentBytes;

  final MemoryMutationCoordinator _mutations;
  final MemoryBackupCodec _codec;
  final DateTime Function() _now;
  final Future<void> Function() _ready;
  final Future<void> Function(Set<String> ids) _personasDeleted;

  Future<String> createBackup() async {
    await _ready();
    final contents = await _mutations.transaction((files) async {
      final result = <String, String>{};
      for (final name in MemoryFiles.coreBackupFiles) {
        result[name] = await files.read(name);
      }
      if (files is PersonaTreeTransaction) {
        final tree = files as PersonaTreeTransaction;
        for (final name in await tree.listPersonaFiles()) {
          result['personas/$name'] = await files.read('personas/$name');
        }
      }
      return result;
    });
    return _codec.encode(contents, _now());
  }

  MemoryRestorePayload decodeRestore(String document) {
    final decoded = _codec.decode(document);
    final version = (jsonDecode(document) as Map)['version'];
    final files = Map<String, String>.of(decoded);
    final legacy = files.remove(MemoryFiles.legacyPersonas);
    if (legacy != null) {
      // V1 conversion is completed asynchronously in preparePreview where the
      // canonical codec and collision checks share the live transaction.
      return MemoryRestorePayload(
        files: files,
        totalBytes: files.values.fold(0, (sum, value) => sum + value.length),
        legacyPersonas: legacy,
        replacePersonas: true,
      );
    }
    return MemoryRestorePayload(
      files: files,
      totalBytes: files.values.fold(0, (sum, value) => sum + value.length),
      replacePersonas: version == MemoryBackupCodec.version,
    );
  }

  Future<MemoryRestorePreview> preparePreview(
    MemoryRestorePayload payload,
    String confirmationToken,
  ) async {
    await _ready();
    final effective = await _effectiveFiles(payload);
    _validateIncomingPersonas(effective);
    return _mutations.transaction((files) async {
      final previews = <String, MemoryRestoreFilePreview>{};
      for (final entry in effective.entries) {
        final current = await _readIfExists(files, entry.key) ?? '';
        final exists = await _readIfExists(files, entry.key) != null;
        previews[entry.key] = MemoryRestoreFilePreview(
          current: current,
          incoming: entry.value,
          diff: _buildDiff(entry.key, current, entry.value),
          currentVersion: checksum(current),
          exists: exists,
        );
      }
      final supportsPersonas = files is PersonaTreeTransaction;
      final existingPersonas = supportsPersonas
          ? (List<String>.of(
              await (files as PersonaTreeTransaction).listPersonaFiles(),
            )..sort())
          : <String>[];
      final incomingPersonas = effective.keys
          .where((name) => name.startsWith('personas/'))
          .toSet();
      final deletions = payload.replacePersonas
          ? existingPersonas
                .map((name) => 'personas/$name')
                .where((name) => !incomingPersonas.contains(name))
                .toSet()
          : <String>{};
      for (final name in deletions) {
        final current = (await _readIfExists(files, name))!;
        previews[name] = MemoryRestoreFilePreview(
          current: current,
          incoming: '',
          diff: _buildDiff(name, current, ''),
          currentVersion: checksum(current),
          exists: true,
          delete: true,
        );
      }
      return MemoryRestorePreview(
        confirmationToken: confirmationToken,
        files: previews,
        totalBytes: effective.values.fold(
          0,
          (sum, value) => sum + value.length,
        ),
        personaMembershipVersion: supportsPersonas
            ? checksum(existingPersonas.join('\n'))
            : '',
      );
    });
  }

  static void _validateIncomingPersonas(Map<String, String> files) {
    const codec = PersonaDocumentCodec();
    var count = 0;
    var aggregate = 0;
    for (final entry in files.entries) {
      if (!entry.key.startsWith('personas/')) continue;
      final name = entry.key.substring(9);
      if (!MemoryFileValidation.isPersonaPath(entry.key)) {
        throw const MemoryBackupFormatException('Unsafe persona path');
      }
      count++;
      aggregate += utf8.encode(entry.value).length;
      if (count > maxPersonas || aggregate > maxPersonaAggregateBytes) {
        throw const MemoryBackupFormatException(
          'Persona backup exceeds limits',
        );
      }
      codec.parse(name.substring(0, name.length - 3), entry.value);
    }
  }

  Future<void> restore(
    MemoryRestorePayload payload,
    MemoryRestorePreview preview,
  ) async {
    await _ready();
    final replacements = {
      for (final entry in preview.files.entries)
        if (!entry.value.delete) entry.key: entry.value.incoming,
    };
    final deletions = {
      for (final entry in preview.files.entries)
        if (entry.value.delete) entry.key,
    };
    await _mutations.mutate(
      event: 'restore_memory_backup',
      replacements: replacements,
      expectedVersions: {
        for (final entry in preview.files.entries)
          if (entry.value.exists) entry.key: entry.value.currentVersion,
      },
      createIfMissing: {
        for (final name in replacements.keys)
          if (preview.files[name]?.exists == false) name,
      },
      deletions: deletions,
      expectedPersonaMembership: preview.personaMembershipVersion.isEmpty
          ? null
          : preview.personaMembershipVersion,
    );
    await _personasDeleted({
      for (final path in deletions) path.substring(9, path.length - 3),
    });
  }

  Future<Map<String, String>> _effectiveFiles(
    MemoryRestorePayload payload,
  ) async {
    if (payload.legacyPersonas == null) return payload.files;
    final result = Map<String, String>.of(payload.files);
    const codec = PersonaDocumentCodec();
    for (final definition in parseLegacyPersonaDefinitions(
      payload.legacyPersonas!,
    )) {
      final metadata = definition.metadata;
      result['personas/${metadata.id}.md'] = codec.serialize(definition);
    }
    return Map.unmodifiable(result);
  }

  static Future<String?> _readIfExists(
    MemoryFileTransaction files,
    String name,
  ) async {
    if (files is MissingAwareMemoryFileTransaction) {
      return (files as MissingAwareMemoryFileTransaction).readIfExists(name);
    }
    try {
      return await files.read(name);
    } on Object {
      return null;
    }
  }
}

class MemoryRestorePayload {
  MemoryRestorePayload({
    required Map<String, String> files,
    required this.totalBytes,
    this.legacyPersonas,
    this.replacePersonas = false,
  }) : files = Map.unmodifiable(Map.of(files));
  final Map<String, String> files;
  final int totalBytes;
  final String? legacyPersonas;
  final bool replacePersonas;
}

class MemoryRestorePreview {
  MemoryRestorePreview({
    required this.confirmationToken,
    required Map<String, MemoryRestoreFilePreview> files,
    required this.totalBytes,
    this.personaMembershipVersion = '',
  }) : files = Map.unmodifiable(Map.of(files));
  final String confirmationToken;
  final Map<String, MemoryRestoreFilePreview> files;
  final int totalBytes;
  final String personaMembershipVersion;
}

class MemoryRestoreFilePreview {
  const MemoryRestoreFilePreview({
    required this.current,
    required this.incoming,
    required this.diff,
    required this.currentVersion,
    this.exists = true,
    this.delete = false,
  });

  final String current;
  final String incoming;
  final String diff;
  final String currentVersion;
  final bool exists;
  final bool delete;
}

String _buildDiff(String fileName, String before, String after) {
  final beforeLines = before.split('\n');
  final afterLines = after.split('\n');
  return '${['--- current/$fileName', '+++ incoming/$fileName', ...beforeLines.map((line) => '-$line'), ...afterLines.map((line) => '+$line')].join('\n')}\n';
}

class UnknownMemoryRestoreException implements Exception {
  const UnknownMemoryRestoreException();
}
