import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/agents/domain/agent_catalog.dart';
import 'package:mobilka/features/agents/domain/agent_definition.dart';
import 'package:mobilka/features/agents/domain/agent_graph.dart';

void main() {
  test('resolves immutable visible subagents for selected primary', () {
    final graph = const AgentGraphResolver().resolve(
      _catalog([
        _entry(_agent('primary', subagents: ['runner'])),
        _entry(_agent('runner', mode: AgentMode.subagent)),
      ]),
    );

    expect(graph.selectedAvailableSubagents.single.definition.id, 'runner');
    expect(
      () => graph.selectedAvailableSubagents.add(
        _entry(_agent('other', mode: AgentMode.subagent)),
      ),
      throwsUnsupportedError,
    );
  });

  for (final fixture in <({String name, List<AgentCatalogEntry> entries})>[
    (
      name: 'missing',
      entries: [
        _entry(_agent('primary', subagents: ['missing'])),
      ],
    ),
    (
      name: 'hidden',
      entries: [
        _entry(_agent('primary', subagents: ['runner'])),
        _entry(_agent('runner', mode: AgentMode.subagent), hidden: true),
      ],
    ),
    (
      name: 'wrong mode',
      entries: [
        _entry(_agent('primary', subagents: ['other'])),
        _entry(_agent('other')),
      ],
    ),
    (
      name: 'duplicate relation',
      entries: [
        _entry(_agent('primary', subagents: ['runner', 'runner'])),
        _entry(_agent('runner', mode: AgentMode.subagent)),
      ],
    ),
  ]) {
    test('rejects ${fixture.name} relation', () {
      final graph = const AgentGraphResolver().resolve(
        _catalog(fixture.entries),
      );
      expect(graph.selectedPrimary, isNull);
      expect(graph.issues, isNotEmpty);
    });
  }

  test('rejects duplicate discovered IDs', () {
    final graph = const AgentGraphResolver().resolve(
      _catalog([
        _entry(_agent('primary', subagents: ['runner'])),
        _entry(_agent('runner', mode: AgentMode.subagent)),
        _entry(_agent('runner', mode: AgentMode.subagent)),
      ]),
    );
    expect(graph.selectedPrimary, isNull);
    expect(graph.issues, isNotEmpty);
  });

  test('rejects cycles even for programmatically supplied definitions', () {
    final graph = const AgentGraphResolver().resolve(
      _catalog([
        _entry(_agent('primary', subagents: ['runner'])),
        _entry(
          _agent('runner', mode: AgentMode.subagent, subagents: ['primary']),
        ),
      ]),
    );
    expect(graph.selectedPrimary, isNull);
    expect(graph.issues.single.message, contains('cycle'));
  });
}

AgentCatalog _catalog(List<AgentCatalogEntry> entries) =>
    AgentCatalog(agents: entries, issues: const [], selectedId: 'primary');

AgentCatalogEntry _entry(AgentDefinition definition, {bool hidden = false}) =>
    AgentCatalogEntry(
      definition: definition,
      origin: AgentOrigin.user,
      location: '${definition.id}.md',
      isHidden: hidden,
      isFavorite: false,
    );

AgentDefinition _agent(
  String id, {
  AgentMode mode = AgentMode.primary,
  List<String> subagents = const [],
}) => AgentDefinition(
  id: id,
  name: id,
  description: id,
  mode: mode,
  prompt: 'Prompt for $id',
  subagents: subagents,
);
