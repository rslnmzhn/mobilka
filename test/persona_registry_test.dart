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
  test('production adapter round-trips names and multiline Unicode', () async {
    var yaml = 'personas: {}\n';
    final registry = PersonaRegistry(
      readYaml: () async => yaml,
      readActive: () => null,
      writeActive: (_) {},
    );
    final adapter = PersonaRegistryAdapterImpl(registry);

    yaml = await adapter.yamlAfter(
      operation: 'save_persona',
      name: 'ревью: #1 "safe"',
      text: 'Первая\n\n  indented\n',
    );
    final entries = await registry.refresh();
    expect(entries.single.name, 'ревью: #1 "safe"');
    expect(entries.single.text, 'Первая\n\n  indented\n');
  });

  test(
    'production adapter refuses malformed source and invalid edits',
    () async {
      var yaml = 'personas: [broken';
      final registry = PersonaRegistry(
        readYaml: () async => yaml,
        readActive: () => null,
        writeActive: (_) {},
      );
      final adapter = PersonaRegistryAdapterImpl(registry);
      await expectLater(
        adapter.yamlAfter(operation: 'save_persona', name: 'x', text: 'y'),
        throwsFormatException,
      );
      await expectLater(
        adapter.yamlAfter(operation: 'unknown', name: 'x', text: 'y'),
        throwsFormatException,
      );
      await expectLater(
        adapter.yamlAfter(operation: 'save_persona', name: '', text: 'y'),
        throwsFormatException,
      );
      yaml = 'personas: {}\n';
      expect(await registry.refresh(), isEmpty);
      expect(registry.lastError, isNull);
    },
  );

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

  test('registry rejects non-string scalars and empty names', () async {
    for (final yaml in [
      'personas:\n  1: text\n',
      'personas:\n  name: 1\n',
      'personas:\n  "": text\n',
      'personas:\n  "  ": text\n',
    ]) {
      final registry = PersonaRegistry(
        readYaml: () async => yaml,
        readActive: () => null,
        writeActive: (_) {},
      );
      expect(await registry.refresh(), isEmpty, reason: yaml);
      expect(registry.lastError, isNotNull, reason: yaml);
    }
  });

  test('registry rejects duplicate names and unsupported controls', () async {
    for (final yaml in [
      'personas:\n  duplicate: one\n  duplicate: two\n',
      'personas:\n  "bad\\u007f": text\n',
      'personas:\n  safe: "bad\\u0001"\n',
    ]) {
      final registry = PersonaRegistry(
        readYaml: () async => yaml,
        readActive: () => null,
        writeActive: (_) {},
      );
      expect(await registry.refresh(), isEmpty, reason: yaml);
      expect(registry.lastError, isNotNull, reason: yaml);
    }
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

  test('valid external deletion clears the active persona', () async {
    var yaml = 'personas:\n  reviewer: x\n';
    String? active = 'reviewer';
    final registry = PersonaRegistry(
      readYaml: () async => yaml,
      readActive: () => active,
      writeActive: (value) => active = value,
    );
    await registry.refresh();

    yaml = 'personas: {}\n';
    await registry.refresh();

    expect(active, isNull);
  });

  test(
    'valid refresh after manual edit or restore reconciles active',
    () async {
      var yaml = 'personas:\n  restored: x\n';
      String? active = 'restored';
      final registry = PersonaRegistry(
        readYaml: () async => yaml,
        readActive: () => active,
        writeActive: (value) => active = value,
      );
      expect((await registry.refresh()).single.name, 'restored');

      yaml = 'personas:\n  manually_added: y\n';
      expect((await registry.refresh()).single.name, 'manually_added');
      expect(active, isNull);
    },
  );

  test('malformed YAML does not clear the active persona', () async {
    String? active = 'reviewer';
    final registry = PersonaRegistry(
      readYaml: () async => 'personas: [broken',
      readActive: () => active,
      writeActive: (value) => active = value,
    );

    expect(await registry.refresh(), isEmpty);
    expect(registry.lastError, isNotNull);
    expect(active, 'reviewer');
  });

  test('transient read failure preserves cache and active persona', () async {
    var fail = false;
    String? active = 'reviewer';
    final registry = PersonaRegistry(
      readYaml: () async {
        if (fail) throw StateError('temporary read failure');
        return 'personas:\n  reviewer: x\n';
      },
      readActive: () => active,
      writeActive: (value) => active = value,
    );
    await registry.refresh();
    fail = true;

    expect((await registry.refresh()).single.name, 'reviewer');
    expect(active, 'reviewer');
    expect(registry.lastError, contains('temporary read failure'));
  });
}
