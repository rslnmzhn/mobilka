import 'dart:typed_data';

import 'package:mobilka/features/memory/data/saf_memory_access.dart';
import 'package:mobilka/features/workspace/data/saf_workspace_models.dart';

final class WorkspaceSafTestAdapter implements WorkspaceSafAccess {
  const WorkspaceSafTestAdapter(this.access);

  final FakeWorkspaceSaf access;

  @override
  Future<List<WorkspaceSafDocument>> list(String directoryUri) async =>
      (await access.list(directoryUri))
          .map(
            (item) => WorkspaceSafDocument(
              uri: item.uri,
              name: item.name,
              isDirectory: item.isDirectory,
              mimeType: item.mimeType,
              size: item.size,
            ),
          )
          .toList();

  @override
  Future<WorkspaceSafDocument> createDirectory(
    String directoryUri,
    String name,
  ) async {
    final item = await access.createDirectory(directoryUri, name);
    return WorkspaceSafDocument(
      uri: item.uri,
      name: item.name,
      isDirectory: item.isDirectory,
      mimeType: item.mimeType,
      size: item.size,
    );
  }
}

final class FakeWorkspaceSaf
    implements SafMemoryAccess, SafMemoryVerifiedAccess {
  static const root = 'content://root';
  static const sessions = 'content://root/sessions';
  static const session = 'content://root/sessions/session';

  final Map<String, List<SafMemoryDocument>> children = {root: []};
  final Map<String, Uint8List> bytes = {};
  var sequence = 0;
  var readCalls = 0;
  var listCalls = 0;
  var fixedLists = false;
  var wrongReturnedUri = false;
  var silentTruncation = false;
  var keepDeletedDocument = false;
  var failDelete = false;

  void seedWorkspace() {
    directory(root, 'sessions', uri: sessions);
    directory(sessions, 'session', uri: session);
    listCalls = 0;
  }

  SafMemoryDocument directory(String parent, String name, {String? uri}) {
    final document = SafMemoryDocument(
      uri: uri ?? '$parent/$name-${sequence++}',
      name: name,
      isDirectory: true,
      size: 0,
    );
    children.putIfAbsent(parent, () => []).add(document);
    children[document.uri] = [];
    return document;
  }

  SafMemoryDocument file(
    String parent,
    String name,
    List<int> content, {
    String mime = 'text/plain',
  }) {
    final uri = '$parent/$name-${sequence++}';
    final document = SafMemoryDocument(
      uri: uri,
      name: name,
      isDirectory: false,
      mimeType: mime,
      size: content.length,
    );
    children.putIfAbsent(parent, () => []).add(document);
    bytes[uri] = Uint8List.fromList(content);
    return document;
  }

  void duplicate(String parent, String name, List<int> content) =>
      file(parent, name, content);

  SafMemoryDocument? named(String parent, String name) =>
      children[parent]?.where((item) => item.name == name).firstOrNull;

  SafMemoryDocument? document(String uri) {
    for (final entries in children.values) {
      final match = entries.where((item) => item.uri == uri).firstOrNull;
      if (match != null) return match;
    }
    return null;
  }

  @override
  Future<List<SafMemoryDocument>> list(String directoryUri) async {
    listCalls++;
    final result = List<SafMemoryDocument>.of(
      children[directoryUri] ?? const [],
    );
    return fixedLists ? List<SafMemoryDocument>.unmodifiable(result) : result;
  }

  @override
  Future<Uint8List> read(String documentUri) async {
    readCalls++;
    return Uint8List.fromList(bytes[documentUri]!);
  }

  @override
  Future<Uint8List> readRange(
    String documentUri, {
    required int start,
    required int count,
  }) async {
    readCalls++;
    final value = bytes[documentUri]!;
    final end = (start + count).clamp(start, value.length);
    return Uint8List.fromList(value.sublist(start, end));
  }

  @override
  Future<void> write(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required bool overwrite,
  }) async {
    await writeVerified(directoryUri, fileName, content, overwrite: overwrite);
  }

  @override
  Future<SafMemoryDocument> writeVerified(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required bool overwrite,
  }) async {
    var document = named(directoryUri, fileName);
    if (document != null && !overwrite) throw StateError('exists');
    document ??= file(directoryUri, fileName, content);
    final stored = silentTruncation && content.isNotEmpty
        ? content.sublist(0, content.length - 1)
        : content;
    bytes[document.uri] = Uint8List.fromList(stored);
    final replacement = SafMemoryDocument(
      uri: document.uri,
      name: document.name,
      isDirectory: false,
      mimeType: document.mimeType,
      size: stored.length,
    );
    final index = children[directoryUri]!.indexOf(document);
    children[directoryUri]![index] = replacement;
    if (!wrongReturnedUri) return replacement;
    return SafMemoryDocument(
      uri: '${replacement.uri}-wrong',
      name: replacement.name,
      isDirectory: false,
      size: replacement.size,
    );
  }

  @override
  Future<SafMemoryDocument> createDirectory(
    String directoryUri,
    String name,
  ) async => directory(directoryUri, name);

  @override
  Future<void> delete(String documentUri) async {
    if (failDelete) throw StateError('delete failed');
    if (keepDeletedDocument) return;
    for (final entries in children.values) {
      entries.removeWhere((item) => item.uri == documentUri);
    }
    children.remove(documentUri);
    bytes.remove(documentUri);
  }
}
