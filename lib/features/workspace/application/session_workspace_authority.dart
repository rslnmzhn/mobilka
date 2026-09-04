import 'dart:async';
import 'dart:convert';

import '../../../core/workspace/workspace_binding.dart';
import '../domain/session_workspace_path.dart';
import '../domain/workspace_models.dart';
import 'session_workspace_boundary.dart';

final class SessionWorkspaceAuthority {
  SessionWorkspaceAuthority({
    required this.conversationId,
    required this.requestId,
    required this.sessionKey,
    required this.binding,
    required this.rootIdentity,
    required SessionWorkspaceBoundary boundary,
    Future<void> Function(SessionWorkspaceBoundary boundary)? recover,
  }) : _boundary = boundary,
       _recover = recover {
    SessionWorkspacePath.parse(sessionKey);
  }

  final String conversationId;
  final String requestId;
  final String sessionKey;
  final WorkspaceBinding binding;
  final String rootIdentity;
  final SessionWorkspaceBoundary _boundary;
  final Future<void> Function(SessionWorkspaceBoundary boundary)? _recover;

  Future<List<WorkspaceEntry>> listFiles({
    String path = '',
    bool recursive = false,
  }) => _recoverThen(() async {
    final parsed = SessionWorkspacePath.parse(path, allowRoot: true);
    final entries = List<WorkspaceEntry>.of(
      await _boundary.list(parsed, recursive: recursive),
    );
    if (entries.length > workspaceMaxListEntries) {
      throw const WorkspaceBoundaryException('listing_limit_exceeded');
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    return List<WorkspaceEntry>.unmodifiable(entries);
  });

  Future<WorkspaceReadResult> readFile(
    String path, {
    int offset = 0,
    int maxBytes = workspaceMaxReadBytes,
  }) => _recoverThen(() {
    if (offset < 0 || maxBytes < 1 || maxBytes > workspaceMaxReadBytes) {
      throw const FormatException('invalid_read_range');
    }
    return _boundary.read(
      SessionWorkspacePath.parse(path),
      offset: offset,
      maxBytes: maxBytes,
    );
  });

  Future<WorkspaceSearchResult> searchFiles(
    String query, {
    String path = '',
    bool caseSensitive = false,
    Duration deadline = const Duration(seconds: 2),
    bool Function()? cancelled,
  }) async {
    if (query.isEmpty) throw const FormatException('query_required');
    final expires = DateTime.now().add(deadline);
    final files = await listFiles(path: path, recursive: true);
    var scanned = 0;
    var truncated = false;
    final matches = <Map<String, Object?>>[];
    final skipped = <Map<String, Object?>>[];
    final needle = caseSensitive ? query : query.toLowerCase();
    for (final file in files.where((item) {
      return item.type == WorkspaceEntryType.file &&
          !_isArtifactPath(item.path);
    })) {
      if (cancelled?.call() == true) {
        throw const WorkspaceBoundaryException('cancelled');
      }
      if (DateTime.now().isAfter(expires)) {
        throw const WorkspaceBoundaryException('search_deadline_exceeded');
      }
      final remaining = workspaceMaxSearchBytes - scanned;
      if (remaining <= 0) {
        truncated = true;
        break;
      }
      final size = file.size;
      if (size == null) {
        skipped.add({'path': file.path, 'reason': 'metadata_unavailable'});
        continue;
      }
      if (size > workspaceMaxTextBytes) {
        skipped.add({'path': file.path, 'reason': 'workspace_file_too_large'});
        continue;
      }
      final bytesToRead = size.clamp(0, remaining);
      ({String text, int bytesRead}) readPrefix;
      try {
        readPrefix = await _readSearchPrefix(
          file,
          bytesToRead,
          expires: expires,
          cancelled: cancelled,
        );
      } on WorkspaceBoundaryException catch (error) {
        if (!const {
          'unsupported_text',
          'workspace_file_too_large',
          'metadata_unavailable',
        }.contains(error.code)) {
          rethrow;
        }
        skipped.add({'path': file.path, 'reason': error.code});
        continue;
      } on FormatException catch (error) {
        if (error.message != 'workspace_file_too_large') rethrow;
        skipped.add({'path': file.path, 'reason': error.message});
        continue;
      }
      scanned += readPrefix.bytesRead;
      final text = readPrefix.text;
      var lineNumber = 0;
      for (final line in const LineSplitter().convert(text)) {
        lineNumber++;
        final haystack = caseSensitive ? line : line.toLowerCase();
        if (haystack.contains(needle)) {
          matches.add({
            'path': file.path,
            'line': lineNumber,
            'excerpt': line.length <= 240 ? line : line.substring(0, 240),
          });
          if (matches.length >= workspaceMaxSearchMatches) {
            return WorkspaceSearchResult(
              matches: matches,
              skipped: skipped,
              truncated: true,
            );
          }
        }
      }
    }
    return WorkspaceSearchResult(
      matches: matches,
      skipped: skipped,
      truncated: truncated,
    );
  }

  Future<({String text, int bytesRead})> _readSearchPrefix(
    WorkspaceEntry file,
    int byteLimit, {
    required DateTime expires,
    required bool Function()? cancelled,
  }) async {
    var offset = 0;
    final output = StringBuffer();
    while (offset < byteLimit) {
      if (cancelled?.call() == true) {
        throw const WorkspaceBoundaryException('cancelled');
      }
      if (DateTime.now().isAfter(expires)) {
        throw const WorkspaceBoundaryException('search_deadline_exceeded');
      }
      final read = await readFile(
        file.path,
        offset: offset,
        maxBytes: (byteLimit - offset).clamp(1, workspaceMaxReadBytes),
      );
      if (read.identity != file.identity ||
          (file.sha256 != null && read.sha256 != file.sha256) ||
          read.nextOffset > byteLimit) {
        throw const WorkspaceBoundaryException('workspace_source_changed');
      }
      if (read.nextOffset == offset) break;
      if (read.nextOffset < offset) {
        throw const WorkspaceBoundaryException('workspace_source_changed');
      }
      output.write(read.content);
      offset = read.nextOffset;
    }
    return (text: output.toString(), bytesRead: offset);
  }

  Future<WorkspaceReadResult> readEntireFile(
    String path, {
    int maxBytes = workspaceMaxTextBytes,
  }) async {
    final entry = await metadata(path);
    if (entry == null || entry.type != WorkspaceEntryType.file) {
      throw const WorkspaceBoundaryException('not_found');
    }
    final size = entry.size;
    if (size == null) {
      throw const WorkspaceBoundaryException('metadata_unavailable');
    }
    if (size > maxBytes) {
      throw const WorkspaceBoundaryException('workspace_file_too_large');
    }
    var offset = 0;
    final content = StringBuffer();
    while (offset < size) {
      final read = await readFile(
        path,
        offset: offset,
        maxBytes: (size - offset).clamp(1, workspaceMaxReadBytes),
      );
      if (read.identity != entry.identity ||
          (entry.sha256 != null && read.sha256 != entry.sha256) ||
          read.nextOffset <= offset) {
        throw const WorkspaceBoundaryException('workspace_source_changed');
      }
      content.write(read.content);
      offset = read.nextOffset;
    }
    return WorkspaceReadResult(
      content: content.toString(),
      size: size,
      sha256: workspaceHash(utf8.encode(content.toString())),
      nextOffset: size,
      truncated: false,
      identity: entry.identity,
    );
  }

  Future<WorkspaceEntry?> metadata(String path) =>
      _recoverThen(() => _boundary.metadata(SessionWorkspacePath.parse(path)));

  Future<T> locked<T>(
    Future<T> Function(SessionWorkspaceBoundary boundary) action,
  ) => synchronized(action);

  Future<T> synchronized<T>(
    Future<T> Function(SessionWorkspaceBoundary boundary) action,
  ) => _boundary.synchronized(() async {
    if (await _boundary.rootIdentity() != rootIdentity) {
      throw const WorkspaceBoundaryException('workspace_binding_changed');
    }
    await _recover?.call(_boundary);
    return action(_boundary);
  });

  Future<T> _recoverThen<T>(Future<T> Function() action) =>
      synchronized((_) => action());
}

final class WorkspaceSearchResult {
  const WorkspaceSearchResult({
    required this.matches,
    required this.skipped,
    required this.truncated,
  });

  final List<Map<String, Object?>> matches;
  final List<Map<String, Object?>> skipped;
  final bool truncated;

  Map<String, Object?> toJson() => {
    'matches': matches,
    'skipped': skipped,
    'skipped_count': skipped.length,
    'truncated': truncated,
  };
}

bool _isArtifactPath(String path) {
  final first = path.split('/').firstOrNull;
  return first?.toLowerCase() == 'artifacts';
}
