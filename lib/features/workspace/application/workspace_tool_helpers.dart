import 'dart:convert';

import '../domain/workspace_models.dart';
import 'session_workspace_boundary.dart';

String requiredWorkspaceString(
  Map<String, Object?> args,
  String key, {
  int? maxBytes,
}) {
  final value = args[key];
  if (value is! String ||
      value.isEmpty ||
      (maxBytes != null && utf8.encode(value).length > maxBytes)) {
    throw FormatException('${key}_invalid');
  }
  return value;
}

String? optionalWorkspaceString(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value != null && value is! String) {
    throw FormatException('${key}_invalid');
  }
  return value as String?;
}

bool? optionalWorkspaceBool(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value != null && value is! bool) throw FormatException('${key}_invalid');
  return value as bool?;
}

int? optionalWorkspaceInt(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value != null && value is! int) throw FormatException('${key}_invalid');
  return value as int?;
}

String workspaceSafeError(Object error) => error is WorkspaceBoundaryException
    ? error.code
    : error is FormatException
    ? error.message
    : 'workspace_io_failed';

Map<String, Object?> publicWorkspaceEntry(WorkspaceEntry entry) => {
  'path': entry.path,
  'type': entry.type.name,
  'size': entry.size,
  if (entry.sha256 != null) 'sha256': entry.sha256,
};
