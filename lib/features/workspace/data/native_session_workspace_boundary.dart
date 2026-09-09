import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../../core/storage/workspace_root_lock.dart';
import '../application/session_workspace_boundary.dart';
import '../domain/session_workspace_path.dart';
import '../domain/workspace_models.dart';

final class NativeSessionWorkspaceBoundary
    implements BinarySessionWorkspaceBoundary {
  NativeSessionWorkspaceBoundary({
    required this.rootPath,
    required this.sessionKey,
    required Future<void> Function() revalidateAccess,
    MethodChannel channel = const MethodChannel(channelName),
  }) : _revalidateAccess = revalidateAccess,
       _channel = channel {
    final parsed = SessionWorkspacePath.parse(sessionKey);
    if (parsed.components.length != 1) {
      throw const FormatException('workspace_session_key_invalid');
    }
  }

  static const channelName = 'mobilka/session_workspace';

  final String rootPath;
  final String sessionKey;
  final Future<void> Function() _revalidateAccess;
  final MethodChannel _channel;
  String? _capturedRootIdentity;

  Map<String, Object?> _arguments(SessionWorkspacePath path) => {
    'root': rootPath,
    'sessionKey': sessionKey,
    'path': path.value,
    if (_capturedRootIdentity != null) 'rootIdentity': _capturedRootIdentity,
  };

  @override
  Future<String> rootIdentity() async {
    final identity = await _invoke<String>('rootIdentity', {'root': rootPath});
    if (identity.isEmpty || utf8.encode(identity).length > 1024) {
      throw const WorkspaceBoundaryException('invalid_native_result');
    }
    final captured = _capturedRootIdentity;
    if (captured != null && captured != identity) {
      throw const WorkspaceBoundaryException('workspace_binding_changed');
    }
    return _capturedRootIdentity = identity;
  }

  @override
  Future<T> synchronized<T>(Future<T> Function() action) async {
    final canonicalRoot = await Directory(rootPath).resolveSymbolicLinks();
    return WorkspaceRootLocks.forPath(canonicalRoot).synchronized(() async {
      await _revalidate();
      return action();
    });
  }

  @override
  Future<List<WorkspaceEntry>> list(
    SessionWorkspacePath path, {
    required bool recursive,
  }) async {
    final result = await _invoke<List<Object?>>('list', {
      ..._arguments(path),
      'recursive': recursive,
    });
    return result.map((value) => _entry(_map(value))).toList(growable: false);
  }

  @override
  Future<WorkspaceReadResult> read(
    SessionWorkspacePath path, {
    required int offset,
    required int maxBytes,
  }) async {
    final result = _map(
      await _invoke<Object?>('read', {
        ..._arguments(path),
        'offset': offset,
        'maxBytes': maxBytes,
      }),
    );
    final bytes = result['bytes'];
    if (bytes is! Uint8List) {
      throw const WorkspaceBoundaryException('invalid_native_result');
    }
    String content;
    try {
      content = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const WorkspaceBoundaryException('unsupported_text');
    }
    return WorkspaceReadResult(
      content: content,
      size: _integer(result, 'size'),
      sha256: _string(result, 'sha256'),
      nextOffset: _integer(result, 'nextOffset'),
      truncated: _boolean(result, 'truncated'),
      identity: _string(result, 'identity'),
    );
  }

  @override
  Future<WorkspaceBinaryReadResult> readBinary(
    SessionWorkspacePath path, {
    required int maxBytes,
  }) async {
    if (maxBytes < 0 || maxBytes > workspaceMaxAggregateBytes) {
      throw const FormatException('workspace_binary_limit_invalid');
    }
    final root = await rootIdentity();
    final result = _map(
      await _invoke<Object?>('readBinary', {
        ..._arguments(path),
        'maxBytes': maxBytes,
      }),
    );
    final bytes = result['bytes'];
    if (bytes is! Uint8List || bytes.length > maxBytes) {
      throw const WorkspaceBoundaryException('invalid_native_result');
    }
    final size = _integer(result, 'size');
    final hash = _string(result, 'sha256');
    if (size != bytes.length || hash != workspaceHash(bytes)) {
      throw const WorkspaceBoundaryException('metadata_changed');
    }
    final afterRoot = await rootIdentity();
    if (afterRoot != root) {
      throw const WorkspaceBoundaryException('workspace_binding_changed');
    }
    return WorkspaceBinaryReadResult(
      bytes: bytes,
      size: size,
      sha256: hash,
      identity: _string(result, 'identity'),
      rootIdentity: root,
    );
  }

  @override
  Future<WorkspaceEntry?> metadata(SessionWorkspacePath path) async {
    final result = await _invoke<Object?>('metadata', _arguments(path));
    return result == null ? null : _entry(_map(result));
  }

  @override
  Future<PreparedWorkspaceMutation> prepareMutation(
    String operationId,
    WorkspaceMutationPlan plan,
  ) async {
    if (plan.bytes case final bytes?) decodeWorkspaceText(bytes);
    final result = _map(
      await _invoke<Object?>('prepareMutation', {
        ..._arguments(plan.path),
        ...plan.toJson(),
        'operationId': operationId,
        if (plan.bytes case final bytes?) 'bytes': Uint8List.fromList(bytes),
      }),
    );
    return PreparedWorkspaceMutation.fromJson(result);
  }

  @override
  Future<void> commitPrepared(PreparedWorkspaceMutation prepared) =>
      _preparedCall('commitPrepared', prepared);

  @override
  Future<WorkspacePreparedState> reconcilePrepared(
    PreparedWorkspaceMutation prepared,
  ) async {
    final value = await _invoke<String>('reconcilePrepared', {
      'root': rootPath,
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
    'root': rootPath,
    'sessionKey': sessionKey,
    'prepared': prepared.toJson(),
  });

  Future<T> _invoke<T>(String method, Map<String, Object?> arguments) async {
    await _revalidate();
    try {
      if (method != 'rootIdentity') {
        final identity = _capturedRootIdentity ?? await rootIdentity();
        arguments = {...arguments, 'rootIdentity': identity};
      }
      return await _channel.invokeMethod<T>(method, arguments) as T;
    } on PlatformException catch (error) {
      throw WorkspaceBoundaryException(error.code);
    } on MissingPluginException {
      throw const WorkspaceBoundaryException('workspace_unsupported');
    }
  }

  Future<void> _revalidate() async {
    try {
      await _revalidateAccess();
    } on Object {
      throw const WorkspaceBoundaryException('workspace_grant_invalid');
    }
  }

  static WorkspaceEntry _entry(Map<Object?, Object?> value) => WorkspaceEntry(
    path: _string(value, 'path'),
    type: switch (_string(value, 'type')) {
      'file' => WorkspaceEntryType.file,
      'directory' => WorkspaceEntryType.directory,
      _ => throw const WorkspaceBoundaryException('invalid_native_result'),
    },
    size: value['size'] == null ? null : _integer(value, 'size'),
    identity: _string(value, 'identity'),
    sha256: value['sha256'] is String ? value['sha256']! as String : null,
  );

  static Map<Object?, Object?> _map(Object? value) {
    if (value is Map<Object?, Object?>) {
      return value;
    }
    throw const WorkspaceBoundaryException('invalid_native_result');
  }

  static String _string(Map<Object?, Object?> map, String key) {
    final value = map[key];
    if (value is String) {
      return value;
    }
    throw const WorkspaceBoundaryException('invalid_native_result');
  }

  static int _integer(Map<Object?, Object?> map, String key) {
    final value = map[key];
    if (value is int) {
      return value;
    }
    throw const WorkspaceBoundaryException('invalid_native_result');
  }

  static bool _boolean(Map<Object?, Object?> map, String key) {
    final value = map[key];
    if (value is bool) {
      return value;
    }
    throw const WorkspaceBoundaryException('invalid_native_result');
  }
}
