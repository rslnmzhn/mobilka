import 'dart:convert';

import 'package:flutter/services.dart';

import '../application/session_workspace_boundary.dart';
import 'saf_workspace_models.dart';

final class SafWorkspaceChannel {
  SafWorkspaceChannel({
    required this.directoryUri,
    required this.sessionKey,
    required Future<void> Function() revalidateAccess,
    required MethodChannel channel,
  }) : _revalidateAccess = revalidateAccess,
       _channel = channel;

  final String directoryUri;
  final String sessionKey;
  final Future<void> Function() _revalidateAccess;
  final MethodChannel _channel;
  String? _capturedRootIdentity;

  Future<String> rootIdentity() async {
    final identity = await invoke<String>('rootIdentity', {
      'treeUri': directoryUri,
      'sessionKey': sessionKey,
    });
    if (identity.isEmpty || utf8.encode(identity).length > 1024) {
      throw const WorkspaceBoundaryException('invalid_native_result');
    }
    final captured = _capturedRootIdentity;
    if (captured != null && captured != identity) {
      throw const WorkspaceBoundaryException('workspace_binding_changed');
    }
    return _capturedRootIdentity = identity;
  }

  Future<T> invoke<T>(String method, Map<String, Object?> arguments) async {
    await revalidate();
    try {
      if (method != 'rootIdentity') {
        if (_capturedRootIdentity == null) await rootIdentity();
        arguments = {...arguments, 'rootIdentity': _capturedRootIdentity};
      }
      final value = await _channel.invokeMethod<Object?>(method, arguments);
      return value as T;
    } on PlatformException catch (error) {
      throw WorkspaceBoundaryException(error.code);
    } on MissingPluginException {
      throw const WorkspaceBoundaryException('workspace_unsupported');
    }
  }

  Future<void> revalidate() async {
    try {
      await _revalidateAccess();
    } on Object {
      throw const WorkspaceBoundaryException('workspace_grant_invalid');
    }
  }

  ListedWorkspaceDocument listedDocument(Object? value) {
    if (value is! Map ||
        value['uri'] is! String ||
        value['documentId'] is! String ||
        (value['documentId']! as String).isEmpty ||
        value['name'] is! String ||
        value['isDirectory'] is! bool ||
        (value['mimeType'] != null && value['mimeType'] is! String) ||
        (value['size'] != null &&
            (value['size'] is! int || (value['size']! as int) < 0))) {
      throw const WorkspaceBoundaryException('invalid_native_result');
    }
    return ListedWorkspaceDocument(
      document: WorkspaceSafDocument(
        uri: value['uri']! as String,
        name: value['name']! as String,
        isDirectory: value['isDirectory']! as bool,
        mimeType: value['mimeType'] as String?,
        size: value['size'] as int?,
      ),
      documentId: value['documentId']! as String,
    );
  }
}
