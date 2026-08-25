import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/persona_registry.dart';
import 'package:yaml/yaml.dart';

class _FakeAdapter implements PersonaRegistryAdapter {
  _FakeAdapter(this.yaml);

  String yaml;
  final List<({String operation, String name, String text})> edits = [];

  @override
  String? get activeName => null;

  @override
  Future<List<PersonaEntry>> refresh() async {
    if (yaml.trim().isEmpty) return const [];
    final doc = loadYaml(yaml) as Map;
    final personas = doc['personas'] as Map? ?? const {};
    return [
      for (final entry in personas.entries)
        PersonaEntry(
          name: entry.key.toString(),
          text: entry.value?.toString() ?? '',
        ),
    ];
  }

  @override
  Future<String> switchTo(String? name) async => 'switched: $name';

  @override
  Future<String> yamlAfter({
    required String operation,
    required String name,
    required String text,
  }) async {
    edits.add((operation: operation, name: name, text: text));
    final entries = await refresh();
    final map = {for (final e in entries) e.name: e.text};
    if (operation == 'save_persona') {
      map[name] = text;
    } else {
      map.remove(name);
    }
    final buf = StringBuffer('personas:\n');
    map.forEach((key, value) {
      buf.writeln('  $key: >-');
      for (final line in value.split('\n')) {
        buf.writeln(line.isEmpty ? '' : '    $line');
      }
    });
    yaml = buf.toString();
    return yaml;
  }
}

void main() {
  test('yamlAfter upserts and deletes personas', () async {
    final adapter = _FakeAdapter('personas:\n');

    final y1 = await adapter.yamlAfter(
      operation: 'save_persona',
      name: 'reviewer',
      text: 'Line one\nLine two',
    );
    expect(y1, contains('  reviewer: >-'));
    expect(y1, contains('    Line one'));
    expect(y1, contains('    Line two'));

    await adapter.yamlAfter(
      operation: 'save_persona',
      name: 'concise',
      text: 'Кратко.',
    );
    final y2 = await adapter.yamlAfter(
      operation: 'delete_persona',
      name: 'reviewer',
      text: '',
    );
    expect(y2, isNot(contains('reviewer')));
    expect(y2, contains('concise'));

    // Result must remain parseable.
    final entries = await adapter.refresh();
    expect(entries.map((e) => e.name), ['concise']);
  });

  test('registry parses personas.yaml content', () async {
    final registry = PersonaRegistry(
      readYaml: () async =>
          'personas:\n  reviewer: >-\n    Ты ревьюер.\n  concise: Кратко.',
      readActive: () => null,
      writeActive: (_) {},
    );

    final entries = await registry.refresh();
    expect(entries.map((e) => e.name), ['reviewer', 'concise']);
    expect(entries.first.text, 'Ты ревьюер.');
  });

  test('unknown active persona yields no overlay', () async {
    final registry = PersonaRegistry(
      readYaml: () async => 'personas:\n  reviewer: x\n',
      readActive: () => 'gone',
      writeActive: (_) {},
    );

    expect(registry.activeName, 'gone');
    expect(await registry.overlayText(), isNull);
  });
}
