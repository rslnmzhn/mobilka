import 'dart:convert';

class StrictJsonObjectParser {
  StrictJsonObjectParser(this._source);
  final String _source;
  var _offset = 0;

  static Map<String, Object?> decode(String source) =>
      StrictJsonObjectParser(source).parse();

  Map<String, Object?> parse() {
    final value = _value(0);
    _space();
    if (_offset != _source.length || value is! Map<String, Object?>) {
      throw const FormatException('params must be a JSON object');
    }
    return Map.unmodifiable(value);
  }

  Object? _value(int depth) {
    if (depth > 8) throw const FormatException('JSON nesting is too deep');
    _space();
    if (_offset >= _source.length) {
      throw const FormatException('Unexpected JSON end');
    }
    return switch (_source[_offset]) {
      '{' => _object(depth + 1),
      '[' => _array(depth + 1),
      '"' => _string(),
      't' => _literal('true', true),
      'f' => _literal('false', false),
      'n' => _literal('null', null),
      _ => _number(),
    };
  }

  Map<String, Object?> _object(int depth) {
    _offset++;
    final result = <String, Object?>{};
    _space();
    if (_take('}')) return result;
    while (true) {
      _space();
      if (_offset >= _source.length || _source[_offset] != '"') {
        throw const FormatException('JSON object key must be a string');
      }
      final key = _string();
      if (result.containsKey(key)) {
        throw FormatException('Duplicate JSON key: $key');
      }
      _space();
      if (!_take(':')) throw const FormatException('Missing JSON colon');
      result[key] = _value(depth);
      _space();
      if (_take('}')) return result;
      if (!_take(',')) throw const FormatException('Missing JSON comma');
    }
  }

  List<Object?> _array(int depth) {
    _offset++;
    final result = <Object?>[];
    _space();
    if (_take(']')) return List.unmodifiable(result);
    while (true) {
      result.add(_value(depth));
      _space();
      if (_take(']')) return List.unmodifiable(result);
      if (!_take(',')) throw const FormatException('Missing JSON comma');
    }
  }

  String _string() {
    final start = _offset++;
    var escaped = false;
    while (_offset < _source.length) {
      final character = _source[_offset++];
      if (!escaped && character == '"') {
        return jsonDecode(_source.substring(start, _offset)) as String;
      }
      escaped = !escaped && character == r'\';
      if (character != r'\') escaped = false;
    }
    throw const FormatException('Unterminated JSON string');
  }

  Object? _literal(String token, Object? value) {
    if (!_source.startsWith(token, _offset)) {
      throw const FormatException('Invalid JSON scalar');
    }
    _offset += token.length;
    return value;
  }

  num _number() {
    final match = RegExp(
      r'-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?',
    ).matchAsPrefix(_source, _offset);
    if (match == null) throw const FormatException('Invalid JSON number');
    _offset = match.end;
    return num.parse(match.group(0)!);
  }

  bool _take(String token) {
    if (!_source.startsWith(token, _offset)) return false;
    _offset += token.length;
    return true;
  }

  void _space() {
    while (_offset < _source.length && ' \r\n\t'.contains(_source[_offset])) {
      _offset++;
    }
  }
}
