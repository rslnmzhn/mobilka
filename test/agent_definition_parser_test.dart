import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/agents/data/agent_definition_parser.dart';
import 'package:mobilka/features/agents/domain/agent_definition.dart';

void main() {
  const parser = AgentDefinitionParser();

  const validDocument = '''---
id: code-assistant
name: "Code Assistant"
description: "Writes and reviews code"
mode: primary
model_preference: openai/gpt-5
subagents:
  - test-runner
tools:
  - update_memory_file
hidden: true
favorite: false
---
# Exact prompt

Keep this trailing whitespace.  
''';

  test('parses every schema field and preserves the Markdown body', () {
    final definition = parser.parse(validDocument);

    expect(definition.id, 'code-assistant');
    expect(definition.name, 'Code Assistant');
    expect(definition.description, 'Writes and reviews code');
    expect(definition.mode, AgentMode.primary);
    expect(definition.modelPreference, 'openai/gpt-5');
    expect(definition.subagents, ['test-runner']);
    expect(definition.tools, ['update_memory_file']);
    expect(definition.isHidden, isTrue);
    expect(definition.isFavorite, isFalse);
    expect(
      definition.prompt,
      '# Exact prompt\n\nKeep this trailing whitespace.  \n',
    );
    expect(() => definition.subagents.add('other'), throwsUnsupportedError);
  });

  test('accepts CRLF boundaries and optional fields', () {
    final definition = parser.parse(
      '---\r\nid: helper\r\nname: Helper\r\n'
      'description: Helps\r\nmode: subagent\r\n---\r\nPrompt\r\n',
    );

    expect(definition.mode, AgentMode.subagent);
    expect(definition.modelPreference, isNull);
    expect(definition.subagents, isEmpty);
    expect(definition.tools, isEmpty);
    expect(definition.isHidden, isFalse);
    expect(definition.isFavorite, isFalse);
    expect(definition.prompt, 'Prompt\r\n');
  });

  test('shipped general assistant uses the standardized schema', () {
    final definition = parser.parse(
      File('assets/agents/general-assistant.md').readAsStringSync(),
    );

    expect(definition.id, 'general-assistant');
    expect(definition.name, 'General Assistant');
    expect(definition.mode, AgentMode.primary);
    expect(definition.tools, contains('update_memory_file'));
    expect(definition.prompt, startsWith('\n## Role & System Instructions'));
  });

  group('rejects malformed frontmatter', () {
    test('missing or malformed delimiters', () {
      expectInvalid('id: agent\n---\nPrompt');
      expectInvalid('----\nid: agent\n---\nPrompt');
      expectInvalid('---\nid: agent\nPrompt');
      expectInvalid('---\nid: agent\n--- trailing\nPrompt');
    });

    test('invalid YAML and unsupported nested syntax', () {
      expectInvalid('${minimalHeader()}name: [unterminated\n---\nPrompt');
      expectInvalid('${minimalHeader()}extra:\n  nested: value\n---\nPrompt');
    });

    test('rejects flow collections before YAML parsing', () {
      for (final value in ['[]', '[test-runner]', '{}', '{name: Agent}']) {
        expectInvalid(
          replace(validDocument, 'name: "Code Assistant"', 'name: $value'),
        );
      }
      expectInvalid(
        replace(
          validDocument,
          'subagents:\n  - test-runner',
          'subagents: [test-runner]',
        ),
      );
    });

    test('rejects anchors, aliases, and explicit tags before YAML parsing', () {
      for (final value in [
        '&agent Agent',
        '*agent',
        '!!str Agent',
        '!custom Agent',
      ]) {
        expectInvalid(
          replace(validDocument, 'name: "Code Assistant"', 'name: $value'),
        );
      }
      expectInvalid(
        replace(validDocument, '  - test-runner', '  - &runner test-runner'),
      );
    });

    test('rejects multiline and nested structures before YAML parsing', () {
      for (final value in ['|', '>', '|-', '>+']) {
        expectInvalid(
          replace(
            validDocument,
            'description: "Writes and reviews code"',
            'description: $value\n  injected text',
          ),
        );
      }
      expectInvalid(
        replace(validDocument, '  - test-runner', '  - runner: value'),
      );
      expectInvalid(
        replace(
          validDocument,
          'subagents:\n  - test-runner',
          'subagents:\n  runner: value',
        ),
      );
      expectInvalid(
        replace(validDocument, '  - test-runner', '  - - test-runner'),
      );
      expectInvalid(
        replace(
          validDocument,
          'name: "Code Assistant"',
          'name:\n  continued text',
        ),
      );
    });

    test('duplicate and unknown fields', () {
      expectInvalid('${minimalHeader()}id: another\n---\nPrompt');
      expectInvalid('${minimalHeader()}version: 1\n---\nPrompt');
    });
  });

  group('rejects schema violations', () {
    test('missing required fields', () {
      expectInvalid('---\nid: agent\nname: Agent\nmode: primary\n---\nPrompt');
    });

    test('wrong scalar and list types', () {
      expectInvalid(
        replace(validDocument, 'name: "Code Assistant"', 'name: 3'),
      );
      expectInvalid(replace(validDocument, 'hidden: true', 'hidden: "true"'));
      expectInvalid(
        replace(
          validDocument,
          'subagents:\n  - test-runner',
          'subagents: test-runner',
        ),
      );
      expectInvalid(
        replace(
          validDocument,
          'tools:\n  - update_memory_file',
          'tools:\n  - 4',
        ),
      );
    });

    test('unknown mode', () {
      expectInvalid(replace(validDocument, 'mode: primary', 'mode: secondary'));
    });

    test('subagent mode cannot declare subagents', () {
      expectInvalid(replace(validDocument, 'mode: primary', 'mode: subagent'));
    });

    test('unsafe IDs and self-reference', () {
      for (final id in ['../agent', 'Agent', '-agent', 'agent.name', 'a/b']) {
        expectInvalid(replace(validDocument, 'id: code-assistant', 'id: $id'));
      }
      expectInvalid(
        replace(validDocument, '  - test-runner', '  - code-assistant'),
      );
      expectInvalid(
        replace(validDocument, '  - update_memory_file', '  - ../tool'),
      );
    });

    test('duplicate list entries', () {
      expectInvalid(
        replace(
          validDocument,
          '  - test-runner',
          '  - test-runner\n  - test-runner',
        ),
      );
    });

    test('empty, padded, and overlong values', () {
      expectInvalid(
        replace(validDocument, 'name: "Code Assistant"', 'name: ""'),
      );
      expectInvalid(
        replace(validDocument, 'name: "Code Assistant"', 'name: " Agent "'),
      );
      expectInvalid(
        replace(validDocument, 'id: code-assistant', 'id: ${'a' * 65}'),
      );
    });
  });

  test('rejects oversized frontmatter and documents', () {
    expectInvalid(
      '---\nid: agent\nname: Agent\ndescription: "${'a' * AgentDefinitionParser.maxFrontmatterBytes}"\n'
      'mode: primary\n---\nPrompt',
    );
    expectInvalid(
      '${minimalDocument()}${'x' * AgentDefinitionParser.maxDocumentBytes}',
    );
  });
}

String minimalHeader() =>
    '---\nid: agent\nname: Agent\ndescription: Description\nmode: primary\n';

String minimalDocument() => '${minimalHeader()}---\nPrompt';

String replace(String source, String from, String to) =>
    source.replaceFirst(from, to);

void expectInvalid(String source) {
  expect(
    () => const AgentDefinitionParser().parse(source),
    throwsA(isA<AgentDefinitionFormatException>()),
  );
}
