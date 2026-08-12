import 'agent_catalog.dart';
import 'agent_definition.dart';

class AgentGraphIssue {
  const AgentGraphIssue({required this.agentId, required this.message});

  final String agentId;
  final String message;
}

class AgentGraph {
  AgentGraph({
    required Map<String, AgentCatalogEntry> validPrimaries,
    required Map<String, List<AgentCatalogEntry>> relations,
    required List<AgentGraphIssue> issues,
    required this.selectedPrimaryId,
  }) : validPrimaries = Map.unmodifiable(validPrimaries),
       relations = Map.unmodifiable(<String, List<AgentCatalogEntry>>{
         for (final MapEntry(:key, :value) in relations.entries)
           key: List<AgentCatalogEntry>.unmodifiable(value),
       }),
       issues = List.unmodifiable(issues);

  final Map<String, AgentCatalogEntry> validPrimaries;
  final Map<String, List<AgentCatalogEntry>> relations;
  final List<AgentGraphIssue> issues;
  final String? selectedPrimaryId;

  AgentCatalogEntry? get selectedPrimary =>
      selectedPrimaryId == null ? null : validPrimaries[selectedPrimaryId];

  List<AgentCatalogEntry> availableSubagents(String primaryId) =>
      relations[primaryId] ?? const [];

  List<AgentCatalogEntry> get selectedAvailableSubagents =>
      selectedPrimaryId == null
      ? const []
      : availableSubagents(selectedPrimaryId!);
}

class AgentGraphResolver {
  const AgentGraphResolver();

  AgentGraph resolve(AgentCatalog catalog) {
    final (:byId, :duplicateIds) = _indexAgents(catalog.agents);
    final issues = <AgentGraphIssue>[];
    final validPrimaries = <String, AgentCatalogEntry>{};
    final relations = <String, List<AgentCatalogEntry>>{};
    for (final entry in catalog.agents) {
      final definition = entry.definition;
      if (duplicateIds.contains(definition.id)) {
        issues.add(
          AgentGraphIssue(
            agentId: definition.id,
            message: 'Duplicate agent id: ${definition.id}',
          ),
        );
        continue;
      }
      if (definition.mode != AgentMode.primary) continue;

      final (:resolved, :invalid) = _resolveRelations(
        definition,
        byId,
        duplicateIds,
      );
      if (invalid != null) {
        issues.add(AgentGraphIssue(agentId: definition.id, message: invalid));
        continue;
      }
      validPrimaries[definition.id] = entry;
      relations[definition.id] = resolved;
    }

    final selected = validPrimaries.containsKey(catalog.selectedId)
        ? catalog.selectedId
        : null;
    return AgentGraph(
      validPrimaries: validPrimaries,
      relations: relations,
      issues: issues,
      selectedPrimaryId: selected,
    );
  }

  ({Map<String, AgentCatalogEntry> byId, Set<String> duplicateIds})
  _indexAgents(List<AgentCatalogEntry> agents) {
    final byId = <String, AgentCatalogEntry>{};
    final duplicateIds = <String>{};
    for (final entry in agents) {
      if (byId.containsKey(entry.definition.id)) {
        duplicateIds.add(entry.definition.id);
      } else {
        byId[entry.definition.id] = entry;
      }
    }
    return (byId: byId, duplicateIds: duplicateIds);
  }

  ({List<AgentCatalogEntry> resolved, String? invalid}) _resolveRelations(
    AgentDefinition definition,
    Map<String, AgentCatalogEntry> byId,
    Set<String> duplicateIds,
  ) {
    final seen = <String>{};
    final resolved = <AgentCatalogEntry>[];
    for (final subagentId in definition.subagents) {
      final invalid = _validateRelation(
        subagentId,
        definition.id,
        seen,
        byId,
        duplicateIds,
      );
      if (invalid != null) return (resolved: resolved, invalid: invalid);
      resolved.add(byId[subagentId]!);
    }
    return (resolved: resolved, invalid: null);
  }

  String? _validateRelation(
    String subagentId,
    String primaryId,
    Set<String> seen,
    Map<String, AgentCatalogEntry> byId,
    Set<String> duplicateIds,
  ) {
    if (!seen.add(subagentId)) {
      return 'Duplicate subagent relation: $subagentId';
    }
    final target = byId[subagentId];
    if (target == null || duplicateIds.contains(subagentId)) {
      return 'Missing or ambiguous subagent: $subagentId';
    }
    if (target.isHidden) return 'Hidden subagent: $subagentId';
    if (target.definition.mode != AgentMode.subagent) {
      return 'Referenced agent is not a subagent: $subagentId';
    }
    if (_reaches(target.definition, primaryId, byId, <String>{})) {
      return 'Agent relation cycle through: $subagentId';
    }
    return null;
  }

  bool _reaches(
    AgentDefinition current,
    String targetId,
    Map<String, AgentCatalogEntry> byId,
    Set<String> visited,
  ) {
    if (current.id == targetId) return true;
    if (!visited.add(current.id)) return false;
    return current.subagents.any((id) {
      final next = byId[id];
      return next != null && _reaches(next.definition, targetId, byId, visited);
    });
  }
}
