import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/chat_message.dart';

const fallbackToolCallMaxAssistantBytes = 256 * 1024;
const fallbackToolCallMaxBlockBytes = 64 * 1024;
const fallbackToolCallMaxCalls = 8;
const fallbackToolCallMaxCandidateFences = 64;
const fallbackToolCallMaxScanWork = fallbackToolCallMaxAssistantBytes * 2;
const fallbackToolCallMaxJsonDepth = 32;
const fallbackToolCallMaxJsonNodes = 4096;

class FallbackToolCallParseResult {
  const FallbackToolCallParseResult({
    required this.calls,
    required this.visibleText,
  });

  final List<ChatToolCall> calls;
  final String visibleText;
}

FallbackToolCallParseResult parseFallbackToolCalls({
  required String assistantText,
  required String requestMessageId,
  required Set<String> previouslyPersistedCallIds,
}) {
  if (utf8.encode(assistantText).length > fallbackToolCallMaxAssistantBytes) {
    return FallbackToolCallParseResult(
      calls: const [],
      visibleText: assistantText,
    );
  }

  final calls = <ChatToolCall>[];
  final signatures = <String>{};
  final removals = <({int start, int end})>[];
  for (final fence in _scanCandidateFences(assistantText)) {
    final parsed = _parseObject(
      assistantText.substring(fence.contentStart, fence.contentEnd),
    );
    if (parsed == null) continue;
    removals.add((start: fence.start, end: fence.end));
    if (calls.length >= fallbackToolCallMaxCalls) continue;
    _addCall(
      parsed,
      requestMessageId,
      calls,
      signatures,
      previouslyPersistedCallIds,
    );
  }

  if (removals.isEmpty && assistantText.trim().startsWith('{')) {
    final trimmed = assistantText.trim();
    final parsed = _parseObject(trimmed);
    if (parsed != null) {
      _addCall(
        parsed,
        requestMessageId,
        calls,
        signatures,
        previouslyPersistedCallIds,
      );
      return FallbackToolCallParseResult(calls: calls, visibleText: '');
    }
  }

  var visibleText = assistantText;
  for (final removal in removals.reversed) {
    visibleText = visibleText.replaceRange(removal.start, removal.end, '');
  }
  return FallbackToolCallParseResult(
    calls: calls,
    visibleText: visibleText.trim(),
  );
}

List<({int start, int contentStart, int contentEnd, int end})>
_scanCandidateFences(String source) {
  final fences = <({int start, int contentStart, int contentEnd, int end})>[];
  var cursor = 0;
  var candidates = 0;
  var work = 0;
  while (cursor < source.length &&
      candidates < fallbackToolCallMaxCandidateFences &&
      work < fallbackToolCallMaxScanWork) {
    final opening = source.indexOf('```', cursor);
    work += opening < 0 ? source.length - cursor : opening - cursor + 3;
    if (opening < 0 || work > fallbackToolCallMaxScanWork) break;
    cursor = opening + 3;
    if (opening > 0 && source.codeUnitAt(opening - 1) != 0x0a) continue;

    final lineEnd = source.indexOf('\n', cursor);
    work += lineEnd < 0 ? source.length - cursor : lineEnd - cursor + 1;
    if (lineEnd < 0 || work > fallbackToolCallMaxScanWork) break;
    final headerEnd = lineEnd > cursor && source.codeUnitAt(lineEnd - 1) == 0x0d
        ? lineEnd - 1
        : lineEnd;
    final header = source.substring(cursor, headerEnd).trimRight();
    if (header != 'json' && header != 'tool_call') {
      cursor = lineEnd + 1;
      continue;
    }
    candidates++;

    final contentStart = lineEnd + 1;
    var closingSearch = contentStart;
    var foundClosing = false;
    while (closingSearch < source.length &&
        work < fallbackToolCallMaxScanWork) {
      final closing = source.indexOf('```', closingSearch);
      work += closing < 0
          ? source.length - closingSearch
          : closing - closingSearch + 3;
      if (closing < 0 || work > fallbackToolCallMaxScanWork) {
        cursor = source.length;
        break;
      }
      final atLineStart =
          closing == contentStart || source.codeUnitAt(closing - 1) == 0x0a;
      final closingLineEnd = source.indexOf('\n', closing + 3);
      work += closingLineEnd < 0
          ? source.length - (closing + 3)
          : closingLineEnd - (closing + 3) + 1;
      final suffixEnd = closingLineEnd < 0 ? source.length : closingLineEnd;
      final suffix = source.substring(closing + 3, suffixEnd).trim();
      if (atLineStart && suffix.isEmpty) {
        var contentEnd = closing;
        if (contentEnd > contentStart &&
            source.codeUnitAt(contentEnd - 1) == 0x0a) {
          contentEnd--;
          if (contentEnd > contentStart &&
              source.codeUnitAt(contentEnd - 1) == 0x0d) {
            contentEnd--;
          }
        }
        fences.add((
          start: opening,
          contentStart: contentStart,
          contentEnd: contentEnd,
          end: suffixEnd,
        ));
        cursor = suffixEnd;
        foundClosing = true;
        break;
      }
      closingSearch = closing + 3;
    }
    if (!foundClosing && cursor != source.length) break;
  }
  return fences;
}

({String name, String arguments})? _parseObject(String source) {
  if (utf8.encode(source).length > fallbackToolCallMaxBlockBytes ||
      !_hasBoundedJsonComplexity(source)) {
    return null;
  }
  try {
    final decoded = jsonDecode(source);
    if (!_hasBoundedDecodedJson(decoded)) return null;
    if (decoded is! Map<String, dynamic>) return null;

    String? name;
    Object? arguments;
    if (_hasExactKeys(decoded, const {'name', 'arguments'}) &&
        decoded['name'] is String) {
      name = decoded['name'] as String;
      arguments = decoded['arguments'];
    } else if (_hasExactKeys(decoded, const {'tool', 'arguments'}) &&
        decoded['tool'] is String) {
      name = decoded['tool'] as String;
      arguments = decoded['arguments'];
    } else if (_hasExactKeys(decoded, const {'type', 'function'}) &&
        decoded['type'] == 'function' &&
        decoded['function'] is Map<String, dynamic>) {
      final function = decoded['function'] as Map<String, dynamic>;
      if (!_hasExactKeys(function, const {'name', 'arguments'}) ||
          function['name'] is! String) {
        return null;
      }
      name = function['name'] as String;
      arguments = function['arguments'];
      if (arguments is String) {
        if (utf8.encode(arguments).length > fallbackToolCallMaxBlockBytes ||
            !_hasBoundedJsonComplexity(arguments)) {
          return null;
        }
        arguments = jsonDecode(arguments);
        if (!_hasBoundedDecodedJson(arguments)) return null;
      }
    }
    if (name == null || name.trim().isEmpty || arguments is! Map) return null;
    return (name: name, arguments: jsonEncode(_canonicalize(arguments)));
  } on FormatException {
    return null;
  }
}

bool _hasBoundedDecodedJson(Object? root) {
  final pending = <({Object? value, int depth})>[(value: root, depth: 1)];
  var nodes = 0;
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    if (current.depth > fallbackToolCallMaxJsonDepth) return false;
    nodes++;
    if (nodes > fallbackToolCallMaxJsonNodes) return false;
    final value = current.value;
    if (value is Map) {
      if (nodes + value.length > fallbackToolCallMaxJsonNodes) return false;
      for (final child in value.values) {
        pending.add((value: child, depth: current.depth + 1));
      }
    } else if (value is List) {
      if (nodes + value.length > fallbackToolCallMaxJsonNodes) return false;
      for (final child in value) {
        pending.add((value: child, depth: current.depth + 1));
      }
    }
  }
  return true;
}

bool _hasExactKeys(Map<String, dynamic> value, Set<String> expected) =>
    value.length == expected.length && value.keys.toSet().containsAll(expected);

bool _hasBoundedJsonComplexity(String source) {
  var depth = 0;
  var flowTokens = 0;
  var inString = false;
  var escaped = false;
  for (final codeUnit in source.codeUnits) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (codeUnit == 0x5c) {
        escaped = true;
      } else if (codeUnit == 0x22) {
        inString = false;
      }
      continue;
    }
    if (codeUnit == 0x22) {
      inString = true;
    } else if (codeUnit == 0x7b || codeUnit == 0x5b) {
      depth++;
      flowTokens++;
      if (depth > 32) return false;
    } else if (codeUnit == 0x7d || codeUnit == 0x5d) {
      depth--;
      if (depth < 0) return false;
    } else if (codeUnit == 0x2c || codeUnit == 0x3a) {
      flowTokens++;
      if (flowTokens > 4096) return false;
    }
  }
  return !inString && depth == 0;
}

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalize(value[key]),
    };
  }
  if (value is List) return value.map(_canonicalize).toList();
  return value;
}

void _addCall(
  ({String name, String arguments}) parsed,
  String requestMessageId,
  List<ChatToolCall> calls,
  Set<String> signatures,
  Set<String> previouslyPersistedCallIds,
) {
  final signature = '${parsed.name}\u0000${parsed.arguments}';
  if (!signatures.add(signature)) return;
  final digest = sha256.convert(
    utf8.encode('$requestMessageId\u0000${calls.length}'),
  );
  final id = 'fallback-${digest.toString().substring(0, 24)}';
  if (previouslyPersistedCallIds.contains(id)) return;
  calls.add(
    ChatToolCall(id: id, name: parsed.name, arguments: parsed.arguments),
  );
}
