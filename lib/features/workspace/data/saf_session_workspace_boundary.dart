import 'dart:convert';

import 'package:flutter/services.dart';

import '../application/session_workspace_boundary.dart';
import '../domain/session_workspace_path.dart';
import '../domain/workspace_models.dart';
import 'saf_workspace_read_support.dart';
import 'saf_workspace_channel.dart';
import 'saf_workspace_models.dart';

final class SafSessionWorkspaceBoundary implements SessionWorkspaceBoundary {
  SafSessionWorkspaceBoundary({
    required String directoryUri,
    required WorkspaceSafAccess access,
    required Future<T> Function<T>(Future<T> Function() action) synchronizeRoot,
    required this.sessionKey,
    required Future<void> Function() revalidateAccess,
    MethodChannel channel = const MethodChannel(channelName),
  }) : _directoryUri = directoryUri,
       _access = access,
       _synchronizeRoot = synchronizeRoot,
       _channel = SafWorkspaceChannel(
         directoryUri: directoryUri,
         sessionKey: sessionKey,
         revalidateAccess: revalidateAccess,
         channel: channel,
       ) {
    final parsed = SessionWorkspacePath.parse(sessionKey);
    if (parsed.components.length != 1) {
      throw const FormatException('workspace_session_key_invalid');
    }
  }

  final String _directoryUri;
  final WorkspaceSafAccess _access;
  final Future<T> Function<T>(Future<T> Function() action) _synchronizeRoot;
  final SafWorkspaceChannel _channel;
  final String sessionKey;

  static const channelName = 'mobilka/session_workspace';

  @override
  Future<String> rootIdentity() => _channel.rootIdentity();

  SafWorkspaceReadSupport get _reads => const SafWorkspaceReadSupport();

  @override
  Future<T> synchronized<T>(Future<T> Function() action) =>
      _synchronizeRoot(() async {
        await _revalidate();
        return action();
      });

  @override
  Future<List<WorkspaceEntry>> list(
    SessionWorkspacePath path, {
    required bool recursive,
  }) async {
    await _revalidate();
    final root = await _sessionRoot(create: false);
    if (root == null) return const [];
    final directory = await _directory(root, path.components);
    if (directory == null) return const [];
    final result = <WorkspaceEntry>[];
    await _listInto(directory, path.value, recursive, result);
    return result;
  }

  Future<void> _listInto(
    String uri,
    String prefix,
    bool recursive,
    List<WorkspaceEntry> output,
  ) async {
    final rawChildren = await _invoke<List<Object?>>('listDocuments', {
      'treeUri': _directoryUri,
      'sessionKey': sessionKey,
      'path': prefix,
    });
    final children = rawChildren
        .map(_channel.listedDocument)
        .toList(growable: true);
    _requireUnique(children.map((item) => item.document).toList());
    children.sort((a, b) => a.document.name.compareTo(b.document.name));
    for (final listed in children) {
      final child = listed.document;
      if (child.name.startsWith('.')) continue;
      _validateChildName(child.name);
      if (output.length >= workspaceMaxListEntries) {
        throw const WorkspaceBoundaryException('listing_limit_exceeded');
      }
      final path = prefix.isEmpty ? child.name : '$prefix/${child.name}';
      output.add(
        WorkspaceEntry(
          path: path,
          type: child.isDirectory
              ? WorkspaceEntryType.directory
              : WorkspaceEntryType.file,
          size: child.isDirectory ? 0 : child.size,
          identity: listed.documentId,
        ),
      );
      if (recursive && child.isDirectory) {
        await _listInto(child.uri, path, true, output);
      }
    }
  }

  @override
  Future<WorkspaceReadResult> read(
    SessionWorkspacePath path, {
    required int offset,
    required int maxBytes,
  }) async {
    await _revalidate();
    final document = await _document(path, directory: false);
    if (document == null) throw const WorkspaceBoundaryException('not_found');
    final before = await _validateDocument(path.value, document);
    if (before == null || before.type != WorkspaceEntryType.file) {
      throw const WorkspaceBoundaryException('metadata_changed');
    }
    final size = before.size;
    if (size > workspaceMaxTextBytes) {
      throw const FormatException('workspace_file_too_large');
    }
    if (offset > size) throw const FormatException('invalid_utf8_offset');
    final native = await _readDocument(path.value, document);
    final bytes = native.bytes;
    final after = native.inspected;
    final validatedAfter = await _validateDocument(path.value, document);
    if (validatedAfter == null) {
      throw const WorkspaceBoundaryException('metadata_changed');
    }
    if (after.documentId != before.documentId ||
        after.size != size ||
        after.sha256 != workspaceHash(bytes) ||
        validatedAfter.documentId != before.documentId ||
        validatedAfter.size != before.size ||
        validatedAfter.sha256 != before.sha256) {
      throw const WorkspaceBoundaryException('metadata_changed');
    }
    String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const WorkspaceBoundaryException('unsupported_text');
    }
    if (!_reads.isUtf8Boundary(bytes, offset)) {
      throw const FormatException('invalid_utf8_offset');
    }
    var end = (offset + maxBytes).clamp(offset, bytes.length);
    while (end > offset && !_reads.isUtf8Boundary(bytes, end)) {
      end--;
    }
    return WorkspaceReadResult(
      content: text.substring(
        utf8.decode(bytes.sublist(0, offset)).length,
        utf8.decode(bytes.sublist(0, end)).length,
      ),
      size: size,
      sha256: workspaceHash(bytes),
      nextOffset: end,
      truncated: end < size,
      identity: before.documentId,
    );
  }

  @override
  Future<WorkspaceEntry?> metadata(SessionWorkspacePath path) async {
    await _revalidate();
    final document = await _document(path);
    if (document == null) return null;
    final inspected = await _validateDocument(path.value, document);
    if (inspected == null) {
      throw const WorkspaceBoundaryException('metadata_changed');
    }
    return WorkspaceEntry(
      path: path.value,
      type: inspected.type,
      size: inspected.size,
      identity: inspected.documentId,
      sha256: inspected.sha256,
    );
  }

  Future<SafInspectedDocument?> _validateDocument(
    String path,
    WorkspaceSafDocument document,
  ) async {
    final value = await _invoke<Object?>('validateDocument', {
      'treeUri': _directoryUri,
      'sessionKey': sessionKey,
      'path': path,
      'documentUri': document.uri,
      'hash': true,
    });
    if (value == null) return null;
    if (value is! Map) {
      throw const WorkspaceBoundaryException('invalid_native_result');
    }
    return SafInspectedDocument.fromJson(value);
  }

  Future<({Uint8List bytes, SafInspectedDocument inspected})> _readDocument(
    String path,
    WorkspaceSafDocument document,
  ) async {
    final value = await _invoke<Object?>('readDocument', {
      'treeUri': _directoryUri,
      'sessionKey': sessionKey,
      'path': path,
      'documentUri': document.uri,
    });
    if (value is! Map || value['bytes'] is! Uint8List) {
      throw const WorkspaceBoundaryException('invalid_native_result');
    }
    return (
      bytes: value['bytes']! as Uint8List,
      inspected: SafInspectedDocument.fromJson(value),
    );
  }

  @override
  Future<PreparedWorkspaceMutation> prepareMutation(
    String operationId,
    WorkspaceMutationPlan plan,
  ) async {
    await _revalidate();
    if (plan.bytes case final bytes?) decodeWorkspaceText(bytes);
    final value = await _invoke<Object?>('prepareMutation', {
      'treeUri': _directoryUri,
      'sessionKey': sessionKey,
      ...plan.toJson(),
      'operationId': operationId,
      if (plan.bytes case final bytes?) 'bytes': Uint8List.fromList(bytes),
    });
    if (value is! Map) {
      throw const WorkspaceBoundaryException('invalid_native_result');
    }
    return PreparedWorkspaceMutation.fromJson(value);
  }

  @override
  Future<void> commitPrepared(PreparedWorkspaceMutation prepared) =>
      _preparedCall('commitPrepared', prepared);

  @override
  Future<WorkspacePreparedState> reconcilePrepared(
    PreparedWorkspaceMutation prepared,
  ) async {
    final value = await _invoke<String>('reconcilePrepared', {
      'treeUri': _directoryUri,
      'sessionKey': sessionKey,
      'prepared': prepared.toJson(),
    });
    return WorkspacePreparedState.values.firstWhere(
      (state) => state.name == value,
      orElse: () =>
          throw const WorkspaceBoundaryException('invalid_native_result'),
    );
  }

  @override
  Future<void> rollbackPrepared(PreparedWorkspaceMutation prepared) =>
      _preparedCall('rollbackPrepared', prepared);

  @override
  Future<void> cleanupPrepared(PreparedWorkspaceMutation prepared) =>
      _preparedCall('cleanupPrepared', prepared);

  Future<void> _preparedCall(
    String method,
    PreparedWorkspaceMutation prepared,
  ) => _invoke<void>(method, {
    'treeUri': _directoryUri,
    'sessionKey': sessionKey,
    'prepared': prepared.toJson(),
  });

  Future<T> _invoke<T>(String method, Map<String, Object?> arguments) =>
      _channel.invoke<T>(method, arguments);

  Future<void> _revalidate() => _channel.revalidate();

  Future<String?> _sessionRoot({required bool create}) async {
    var current = _directoryUri;
    for (final name in ['sessions', sessionKey]) {
      var child = await _exact(current, name, allowMissing: true);
      if (child == null && create) {
        try {
          child = await _access.createDirectory(current, name);
        } on Object {
          throw const WorkspaceBoundaryException('mutation_indeterminate');
        }
      }
      if (child == null) return null;
      if (!child.isDirectory) {
        throw const WorkspaceBoundaryException('wrong_type');
      }
      final verified = create
          ? await _exactAfterSideEffect(current, name)
          : await _exact(current, name);
      if (verified == null ||
          verified.uri != child.uri ||
          !verified.isDirectory) {
        throw const WorkspaceBoundaryException('ambiguous_child');
      }
      current = child.uri;
    }
    return current;
  }

  Future<String?> _directory(String root, List<String> parts) async {
    var current = root;
    for (final name in parts) {
      final child = await _exact(current, name, allowMissing: true);
      if (child == null) return null;
      if (!child.isDirectory) {
        throw const WorkspaceBoundaryException('wrong_type');
      }
      current = child.uri;
    }
    return current;
  }

  Future<WorkspaceSafDocument?> _document(
    SessionWorkspacePath path, {
    bool? directory,
  }) async {
    final root = await _sessionRoot(create: false);
    if (root == null) return null;
    final parent = await _directory(
      root,
      path.components.sublist(0, path.components.length - 1),
    );
    if (parent == null) return null;
    final item = await _exact(parent, path.components.last, allowMissing: true);
    if (item != null && directory != null && item.isDirectory != directory) {
      throw const WorkspaceBoundaryException('wrong_type');
    }
    return item;
  }

  Future<WorkspaceSafDocument?> _exact(
    String parent,
    String name, {
    bool allowMissing = false,
  }) async {
    final children = await _access.list(parent);
    if (children.length > workspaceMaxListEntries) {
      throw const WorkspaceBoundaryException('listing_limit_exceeded');
    }
    WorkspaceSafDocument? match;
    for (final item in children) {
      if (item.name != name) continue;
      if (match != null) {
        throw const WorkspaceBoundaryException('ambiguous_child');
      }
      match = item;
    }
    if (match == null && allowMissing) return null;
    if (match == null) {
      throw const WorkspaceBoundaryException('ambiguous_child');
    }
    return match;
  }

  Future<WorkspaceSafDocument> _exactAfterSideEffect(
    String parent,
    String name,
  ) async {
    try {
      return (await _exact(parent, name))!;
    } on Object {
      throw const WorkspaceBoundaryException('mutation_indeterminate');
    }
  }

  void _requireUnique(List<WorkspaceSafDocument> children) {
    final names = <String>{};
    if (children.any((item) => !names.add(item.name))) {
      throw const WorkspaceBoundaryException('ambiguous_child');
    }
  }

  void _validateChildName(String name) {
    try {
      final path = SessionWorkspacePath.parse(name);
      if (path.components.length != 1) throw const FormatException();
    } on FormatException {
      throw const WorkspaceBoundaryException('unsafe_child');
    }
  }
}
