import 'dart:convert';

import '../domain/session_workspace_path.dart';
import '../domain/workspace_models.dart';

final class UnifiedPatch {
  const UnifiedPatch._(this.path, this.hunks);
  final String path;
  final List<UnifiedPatchHunk> hunks;

  static UnifiedPatch parse(String source, String expectedPath) {
    if (utf8.encode(source).length > workspaceMaxPatchBytes ||
        source.contains('\r')) {
      throw const FormatException('invalid_patch');
    }
    final lines = source.split('\n');
    if (lines.length > workspaceMaxPatchLines ||
        lines.length < 3 ||
        !lines[0].startsWith('--- ') ||
        !lines[1].startsWith('+++ ')) {
      throw const FormatException('invalid_patch_headers');
    }
    final oldPath = _headerPath(lines[0].substring(4));
    final newPath = _headerPath(lines[1].substring(4));
    if (oldPath != expectedPath || newPath != expectedPath) {
      throw const FormatException('patch_path_mismatch');
    }
    SessionWorkspacePath.parse(expectedPath);
    final hunks = <UnifiedPatchHunk>[];
    var index = 2;
    while (index < lines.length && lines[index].isNotEmpty) {
      final match = RegExp(
        r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@$',
      ).firstMatch(lines[index]);
      if (match == null) throw const FormatException('invalid_patch_hunk');
      final body = <String>[];
      index++;
      while (index < lines.length && !lines[index].startsWith('@@ ')) {
        final line = lines[index];
        if (line.isEmpty && index == lines.length - 1) break;
        if (line.isEmpty || !' +-'.contains(line[0])) {
          throw const FormatException('invalid_patch_line');
        }
        body.add(line);
        index++;
      }
      hunks.add(
        UnifiedPatchHunk(
          oldStart: int.parse(match.group(1)!),
          oldCount: int.parse(match.group(2) ?? '1'),
          newStart: int.parse(match.group(3)!),
          newCount: int.parse(match.group(4) ?? '1'),
          lines: body,
        ),
      );
      if (hunks.length > workspaceMaxPatchHunks) {
        throw const FormatException('patch_hunk_limit');
      }
    }
    if (hunks.isEmpty) throw const FormatException('patch_requires_hunks');
    return UnifiedPatch._(expectedPath, hunks);
  }

  String apply(String original) {
    final finalNewline = original.endsWith('\n');
    final oldLines = original.isEmpty
        ? <String>[]
        : original
              .substring(
                0,
                finalNewline ? original.length - 1 : original.length,
              )
              .split('\n');
    final output = <String>[];
    var cursor = 0;
    for (final hunk in hunks) {
      final start = hunk.oldStart == 0 ? 0 : hunk.oldStart - 1;
      if (start < cursor || start > oldLines.length) {
        throw const FormatException('patch_context_mismatch');
      }
      output.addAll(oldLines.sublist(cursor, start));
      var oldCursor = start;
      var removed = 0;
      var added = 0;
      for (final line in hunk.lines) {
        final value = line.substring(1);
        if (line[0] == ' ') {
          if (oldCursor >= oldLines.length || oldLines[oldCursor] != value) {
            throw const FormatException('patch_context_mismatch');
          }
          output.add(value);
          oldCursor++;
          removed++;
          added++;
        } else if (line[0] == '-') {
          if (oldCursor >= oldLines.length || oldLines[oldCursor] != value) {
            throw const FormatException('patch_context_mismatch');
          }
          oldCursor++;
          removed++;
        } else {
          output.add(value);
          added++;
        }
      }
      if (removed != hunk.oldCount || added != hunk.newCount) {
        throw const FormatException('patch_count_mismatch');
      }
      cursor = oldCursor;
    }
    output.addAll(oldLines.sublist(cursor));
    final result = output.join('\n') + (finalNewline ? '\n' : '');
    encodeWorkspaceText(result);
    return result;
  }

  static String _headerPath(String value) {
    if (value.contains('\t') ||
        value == '/dev/null' ||
        value.startsWith('a/') ||
        value.startsWith('b/')) {
      throw const FormatException('invalid_patch_headers');
    }
    return value;
  }
}

final class UnifiedPatchHunk {
  const UnifiedPatchHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.lines,
  });
  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<String> lines;
}
