import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

import '../domain/agent_catalog.dart';
import '../domain/agent_definition.dart';
import 'agent_definition_parser.dart';
import 'agent_definition_serializer.dart';

typedef AgentAssetLoader = Future<Map<String, String>> Function();
typedef AgentDirectoryProvider = Future<Directory> Function();

class AgentCatalogStorage {
  AgentCatalogStorage({
    AgentDefinitionParser parser = const AgentDefinitionParser(),
    AgentDefinitionSerializer serializer = const AgentDefinitionSerializer(),
    AgentAssetLoader? assetLoader,
    AgentDirectoryProvider? directoryProvider,
  }) : _parser = parser,
       _serializer = serializer,
       _assetLoader = assetLoader ?? _loadBundledAssets,
       _directoryProvider = directoryProvider ?? _defaultDirectory;

  final AgentDefinitionParser _parser;
  final AgentDefinitionSerializer _serializer;
  final AgentAssetLoader _assetLoader;
  final AgentDirectoryProvider _directoryProvider;
  static final Lock _lock = Lock();
  static final Random _random = Random.secure();

  Future<AgentDiscoveryResult> discover() =>
      _lock.synchronized(_discoverUnlocked);

  Future<void> importDefinition(AgentDefinition definition) =>
      create(definition);

  Future<void> create(AgentDefinition definition) async {
    final source = _serializer.serialize(definition);
    await _lock.synchronized(() async {
      await _ensureUnique(definition.id);
      await _writeAtomically(definition.id, source);
    });
  }

  Future<void> edit(String existingId, AgentDefinition definition) async {
    final source = _serializer.serialize(definition);
    await _lock.synchronized(() async {
      final discovery = await _discoverUnlocked();
      final existing = discovery.documents
          .where((agent) => agent.definition.id == existingId)
          .firstOrNull;
      if (existing == null || existing.origin != AgentOrigin.user) {
        throw StateError('Only existing user agents can be edited');
      }
      if (definition.id != existingId) {
        await _ensureUnique(definition.id, discovery: discovery);
      }
      await _writeAtomically(definition.id, source);
      if (definition.id != existingId) await _deleteRegular(existing.location);
    });
  }

  Future<void> delete(String id) => _lock.synchronized(() async {
    final discovery = await _discoverUnlocked();
    final existing = discovery.documents
        .where((agent) => agent.definition.id == id)
        .firstOrNull;
    if (existing == null || existing.origin != AgentOrigin.user) {
      throw StateError('Only existing user agents can be deleted');
    }
    await _deleteRegular(existing.location);
  });

  Future<void> _ensureUnique(
    String id, {
    AgentDiscoveryResult? discovery,
  }) async {
    final current = discovery ?? await _discoverUnlocked();
    if (current.documents.any((agent) => agent.definition.id == id)) {
      throw StateError('An agent with id "$id" already exists');
    }
  }

  Future<AgentDiscoveryResult> _discoverUnlocked() async {
    final entries = <AgentDocument>[];
    final issues = <AgentDiscoveryIssue>[];
    final ids = <String>{};
    final assets = await _assetLoader();
    for (final location in assets.keys.toList()..sort()) {
      _addDocument(
        entries,
        issues,
        ids,
        location,
        assets[location]!,
        AgentOrigin.bundled,
      );
    }

    final directory = await _directoryProvider();
    if (await directory.exists()) {
      final files = await directory
          .list(followLinks: false)
          .where((entity) => entity is File && entity.path.endsWith('.md'))
          .cast<File>()
          .toList();
      files.sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        try {
          _addDocument(
            entries,
            issues,
            ids,
            file.path,
            await readBoundedFile(file),
            AgentOrigin.user,
          );
        } on Object catch (error) {
          issues.add(
            AgentDiscoveryIssue(location: file.path, message: '$error'),
          );
        }
      }
    }
    return AgentDiscoveryResult(
      documents: List.unmodifiable(entries),
      issues: List.unmodifiable(issues),
    );
  }

  void _addDocument(
    List<AgentDocument> entries,
    List<AgentDiscoveryIssue> issues,
    Set<String> ids,
    String location,
    String source,
    AgentOrigin origin,
  ) {
    try {
      final definition = _parser.parse(source);
      if (!ids.add(definition.id)) {
        issues.add(
          AgentDiscoveryIssue(
            location: location,
            message: 'Duplicate agent id: ${definition.id}',
          ),
        );
        return;
      }
      entries.add(
        AgentDocument(
          definition: definition,
          origin: origin,
          location: location,
        ),
      );
    } on Object catch (error) {
      issues.add(AgentDiscoveryIssue(location: location, message: '$error'));
    }
  }

  Future<void> _writeAtomically(String id, String source) async {
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Agent storage path is not a regular directory');
    }
    final separator = Platform.pathSeparator;
    final destination = File('${directory.path}$separator$id.md');
    await _requireRegularOrMissing(destination.path);
    final temp = File(
      '${directory.path}$separator.$id.${_random.nextInt(1 << 32)}.tmp',
    );
    try {
      if (await FileSystemEntity.type(temp.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('Temporary agent path already exists');
      }
      await temp.create(exclusive: true);
      final handle = await temp.open(mode: FileMode.writeOnly);
      try {
        await handle.writeFrom(utf8.encode(source));
        await handle.flush();
      } finally {
        await handle.close();
      }
      await _requireRegularOrMissing(destination.path);
      if (await FileSystemEntity.type(temp.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw StateError('Temporary agent path is not a regular file');
      }
      await temp.rename(destination.path);
    } finally {
      final type = await FileSystemEntity.type(temp.path, followLinks: false);
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.link) {
        await temp.delete();
      }
    }
  }

  Future<void> _deleteRegular(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Agent path is not a regular file');
    }
    await File(path).delete();
  }

  Future<void> _requireRegularOrMissing(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw StateError('Agent path is not a regular file');
    }
  }

  static Future<String> readBoundedFile(File file) async {
    final length = await file.length();
    if (length > AgentDefinitionParser.maxDocumentBytes) {
      throw const AgentDefinitionFormatException('Agent document is too large');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(
      0,
      AgentDefinitionParser.maxDocumentBytes + 1,
    )) {
      bytes.add(chunk);
      if (bytes.length > AgentDefinitionParser.maxDocumentBytes) {
        throw const AgentDefinitionFormatException(
          'Agent document is too large',
        );
      }
    }
    return utf8.decode(bytes.takeBytes());
  }

  static Future<Map<String, String>> _loadBundledAssets() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final paths = manifest.listAssets().where(
      (path) => path.startsWith('assets/agents/') && path.endsWith('.md'),
    );
    return {for (final path in paths) path: await rootBundle.loadString(path)};
  }

  static Future<Directory> _defaultDirectory() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}${Platform.pathSeparator}agents');
  }
}
