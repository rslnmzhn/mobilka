import 'dart:convert';

/// Lexical and structural gate applied before the YAML package sees input.
/// It accepts the small block-mapping subset used by legacy personas and the
/// canonical frontmatter serializer, and rejects YAML's executable graph and
/// implicit-type features.
class StrictYamlPreflight {
  const StrictYamlPreflight._();

  static void validate(
    String source, {
    required int maxBytes,
    int maxDepth = 8,
    int maxEntries = 512,
  }) {
    if (utf8.encode(source).length > maxBytes) {
      throw const FormatException('YAML exceeds its byte limit');
    }
    final keys = <int, Set<String>>{};
    var entries = 0;
    for (final raw in const LineSplitter().convert(source)) {
      if (raw.trim().isEmpty || raw.trimLeft().startsWith('#')) continue;
      if (raw.startsWith('%') || raw.contains('\t')) {
        throw const FormatException('YAML directives and tabs are forbidden');
      }
      final indent = raw.length - raw.trimLeft().length;
      if (indent.isOdd || indent ~/ 2 > maxDepth) {
        throw const FormatException('YAML nesting is invalid');
      }
      final text = raw.substring(indent);
      final colon = _mappingColon(text);
      if (colon <= 0) {
        if (text.startsWith('- ')) {
          throw const FormatException('YAML sequences are unsupported');
        }
        continue; // block scalar continuation
      }
      final keyToken = text.substring(0, colon).trim();
      if (indent == 0 &&
          (keyToken.startsWith('"') || keyToken.startsWith("'"))) {
        throw const FormatException('Quoted top-level YAML keys are forbidden');
      }
      final key = _stringToken(keyToken);
      if (key == null || key == '<<') {
        throw const FormatException('YAML mapping keys must be safe strings');
      }
      final level = indent ~/ 2;
      keys.removeWhere((depth, _) => depth > level);
      if (!(keys[level] ??= <String>{}).add(key)) {
        throw FormatException('Duplicate YAML key: $key');
      }
      if (++entries > maxEntries) {
        throw const FormatException('YAML has too many entries');
      }
      _validateValue(text.substring(colon + 1).trim());
    }
  }

  static int _mappingColon(String text) {
    var quote = 0;
    var escaped = false;
    for (var index = 0; index < text.length; index++) {
      final code = text.codeUnitAt(index);
      if (escaped) {
        escaped = false;
        continue;
      }
      if (quote == 34 && code == 92) {
        escaped = true;
        continue;
      }
      if (code == 34 || code == 39) {
        quote = quote == 0 ? code : (quote == code ? 0 : quote);
      } else if (quote == 0 && code == 58) {
        return index;
      }
    }
    return -1;
  }

  static String? _stringToken(String token) {
    if (token.isEmpty) return null;
    if (token.startsWith('"') && token.endsWith('"')) {
      try {
        final value = jsonDecode(token);
        return value is String ? value : null;
      } on Object {
        return null;
      }
    }
    if (token.startsWith("'") && token.endsWith("'")) {
      return token.substring(1, token.length - 1).replaceAll("''", "'");
    }
    return RegExp(r'^[A-Za-z0-9 _.-]+$').hasMatch(token) ? token : null;
  }

  static void _validateValue(String value) {
    if (value.isEmpty || value == '|' || value == '>-') return;
    final unquoted = !(value.startsWith('"') || value.startsWith("'"));
    if (_containsForbidden(value) ||
        (unquoted &&
            (RegExp(r'^\d{4}-\d\d?-\d\d?').hasMatch(value) ||
                const {
                  'null',
                  '~',
                  'true',
                  'false',
                }.contains(value.toLowerCase())))) {
      throw const FormatException('Unsupported or unsafe YAML scalar');
    }
  }

  static bool _containsForbidden(String value) {
    var quote = 0;
    var escaped = false;
    for (var index = 0; index < value.length; index++) {
      final code = value.codeUnitAt(index);
      if (escaped) {
        escaped = false;
        continue;
      }
      if (quote == 34 && code == 92) {
        escaped = true;
        continue;
      }
      if (code == 34 || code == 39) {
        quote = quote == 0 ? code : (quote == code ? 0 : quote);
        continue;
      }
      if (quote == 0 && (code == 38 || code == 42 || code == 33)) return true;
    }
    return value.contains('<<:') || value.contains('!!binary');
  }
}
