import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/fallback_tool_call_parser.dart';

void main() {
  FallbackToolCallParseResult parse(
    String text, {
    Set<String> prior = const {},
  }) => parseFallbackToolCalls(
    assistantText: text,
    requestMessageId: 'request-1',
    previouslyPersistedCallIds: prior,
  );

  test('accepts fenced name and tool forms and strips recognized blocks', () {
    final result = parse('''Before
```tool_call
{"name":"first","arguments":{"b":2,"a":1}}
```
Between
```json
{"tool":"second","arguments":{}}
```
After''');

    expect(result.calls.map((call) => call.name), ['first', 'second']);
    expect(result.calls.first.arguments, '{"a":1,"b":2}');
    expect(result.visibleText, 'Before\n\nBetween\n\nAfter');
  });

  test('accepts OpenAI function form with object or encoded arguments', () {
    final object = parse('''```json
{"type":"function","function":{"name":"one","arguments":{"x":true}}}
```''');
    final encoded = parse('''```tool_call
{"type":"function","function":{"name":"two","arguments":"{\\"x\\":true}"}}
```''');

    expect(object.calls.single.arguments, '{"x":true}');
    expect(encoded.calls.single.arguments, '{"x":true}');
  });

  test('accepts raw JSON only when it is the entire trimmed text', () {
    final result = parse('  {"name":"raw","arguments":{"items":[2,1]}}  ');

    expect(result.calls.single.name, 'raw');
    expect(result.visibleText, isEmpty);
    expect(parse('Use {"name":"raw","arguments":{}} now').calls, isEmpty);
  });

  test('ignores malformed and unknown structures', () {
    expect(parse('```json\n{"name":\n```').calls, isEmpty);
    expect(
      parse('```json\n{"name":"x","arguments":{},"extra":1}\n```').calls,
      isEmpty,
    );
    expect(parse('```yaml\n{"name":"x","arguments":{}}\n```').calls, isEmpty);
  });

  test('rejects oversized assistant text and blocks', () {
    final oversizedAssistant =
        '${'a' * fallbackToolCallMaxAssistantBytes}\n'
        '```json\n{"name":"x","arguments":{}}\n```';
    final oversizedBlock =
        '```json\n{"name":"x","arguments":{"x":"${'a' * fallbackToolCallMaxBlockBytes}"}}\n```';

    expect(parse(oversizedAssistant).calls, isEmpty);
    expect(parse(oversizedBlock).calls, isEmpty);
  });

  test('rejects suspicious nesting before decode', () {
    final nested = '${'[' * 33}${']' * 33}';
    expect(
      parse('```json\n{"name":"x","arguments":{"x":$nested}}\n```').calls,
      isEmpty,
    );
  });

  test('limits calls to eight and suppresses duplicate name and arguments', () {
    final blocks = List.generate(
      10,
      (index) =>
          '```json\n{"name":"tool_$index","arguments":{"i":$index}}\n```',
    ).join('\n');
    final limited = parse(blocks);
    final duplicate = parse('''```json
{"name":"same","arguments":{"b":2,"a":1}}
```
```tool_call
{"tool":"same","arguments":{"a":1,"b":2}}
```''');

    expect(limited.calls, hasLength(fallbackToolCallMaxCalls));
    expect(limited.visibleText, isEmpty);
    expect(duplicate.calls, hasLength(1));
  });

  test('rejects decoded JSON beyond the nesting limit', () {
    final nested =
        '${'[' * (fallbackToolCallMaxJsonDepth + 1)}0'
        '${']' * (fallbackToolCallMaxJsonDepth + 1)}';
    final text =
        '''```json
{"name":"deep","arguments":$nested}
```''';

    final result = parse(text);

    expect(result.calls, isEmpty);
    expect(result.visibleText, text);
  });

  test('rejects decoded collections beyond the aggregate node limit', () {
    final items = List<int>.filled(fallbackToolCallMaxJsonNodes, 0);
    final text =
        '''```tool_call
${jsonEncode({'name': 'huge', 'arguments': items})}
```''';

    final result = parse(text);

    expect(result.calls, isEmpty);
    expect(result.visibleText, text);
  });

  test('bounds candidate fences and leaves excess candidates visible', () {
    final blocks = List.generate(
      fallbackToolCallMaxCandidateFences + 4,
      (index) => '```json\n{"name":"call$index","arguments":{}}\n```',
    ).join('\n');

    final result = parse(blocks);

    expect(result.calls, hasLength(fallbackToolCallMaxCalls));
    expect(
      result.visibleText,
      contains('call$fallbackToolCallMaxCandidateFences'),
    );
  });

  test('many unmatched fences and near-fences terminate without parsing', () {
    final text = List.generate(
      fallbackToolCallMaxCandidateFences * 4,
      (index) => index.isEven
          ? '```jsonish\n{"name":"near$index","arguments":{}}'
          : 'prefix ```json\n{"name":"inline$index","arguments":{}}',
    ).join('\n');

    final result = parse(text);

    expect(result.calls, isEmpty);
    expect(result.visibleText, text);
  });

  test('unmatched candidate fence stops safely within the scan budget', () {
    final text = '```json\n${'x' * (fallbackToolCallMaxScanWork ~/ 2)}';

    final result = parse(text);

    expect(result.calls, isEmpty);
    expect(result.visibleText, text);
  });

  test('synthetic IDs are deterministic and suppress persisted retries', () {
    const source = '```json\n{"name":"same","arguments":{}}\n```';
    final first = parse(source);
    final second = parse(source);
    final retried = parse(source, prior: {first.calls.single.id});

    expect(second.calls.single.id, first.calls.single.id);
    expect(retried.calls, isEmpty);
  });

  test('byte bounds apply to UTF-8 rather than code units', () {
    final text = jsonEncode({
      'name': 'x',
      'arguments': {'x': 'é' * (fallbackToolCallMaxBlockBytes ~/ 2)},
    });
    expect(parse('```json\n$text\n```').calls, isEmpty);
  });
}
