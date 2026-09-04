import 'dart:convert';

import 'package:crypto/crypto.dart';

const workspaceMaxEntries = 256;
const workspaceMaxAggregateBytes = 10 * 1024 * 1024;
const workspaceMaxTextBytes = 1024 * 1024;
const workspaceMaxReadBytes = 256 * 1024;
const workspaceMaxListEntries = 500;
const workspaceMaxSearchBytes = 2 * 1024 * 1024;
const workspaceMaxSearchMatches = 200;
const workspaceMaxPatchBytes = 256 * 1024;
const workspaceMaxPatchHunks = 100;
const workspaceMaxPatchLines = 10000;
const workspaceMaxPreviewBytes = 1024 * 1024;
const workspaceMaxToolArgumentsBytes = 1280 * 1024;
const workspaceMaxProposalBytes = 2 * 1024 * 1024;

enum WorkspaceEntryType { file, directory }

final class WorkspaceEntry {
  const WorkspaceEntry({
    required this.path,
    required this.type,
    required this.size,
    required this.identity,
    this.sha256,
  });

  final String path;
  final WorkspaceEntryType type;
  final int? size;
  final String identity;
  final String? sha256;

  Map<String, Object?> toJson() => {
    'path': path,
    'type': type.name,
    'size': size,
    'identity': identity,
    if (sha256 != null) 'sha256': sha256,
  };
}

final class WorkspaceReadResult {
  const WorkspaceReadResult({
    required this.content,
    required this.size,
    required this.sha256,
    required this.nextOffset,
    required this.truncated,
    required this.identity,
  });

  final String content;
  final int size;
  final String sha256;
  final int nextOffset;
  final bool truncated;
  final String identity;

  Map<String, Object?> toJson() => {
    'ok': true,
    'content': content,
    'size': size,
    'sha256': sha256,
    'next_offset': nextOffset,
    'truncated': truncated,
  };
}

String workspaceHash(List<int> bytes) => sha256.convert(bytes).toString();

String decodeWorkspaceText(List<int> bytes) {
  if (bytes.length > workspaceMaxTextBytes) {
    throw const FormatException('workspace_file_too_large');
  }
  return utf8.decode(bytes, allowMalformed: false);
}

List<int> encodeWorkspaceText(String content) {
  final bytes = utf8.encode(content);
  if (bytes.length > workspaceMaxTextBytes) {
    throw const FormatException('workspace_file_too_large');
  }
  return bytes;
}
