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
    final byId = <String, AgentCatalogEntry>{};
    final duplicateIds = <String>{};
    for (final entry in catalog.agents) {
      if (byId.containsKey(entry.definition.id)) {
        duplicateIds.add(entry.definition.id);
      } else {
        byId[entry.definition.id] = entry;
      }
    }

    final issues = <AgentGraphIssue>[];
    final validPrimaries = <String, AgentCatalogEntry>{};
    final relations = <String, List<AgentCatalogEntry>>{};
    for (final entry in catalog.agents) {
      final definition = entry.definition;
      if (definition.mode != AgentMode.primary ||
          duplicateIds.contains(definition.id)) {
        if (duplicateIds.contains(definition.id)) {
          issues.add(
            AgentGraphIssue(
              agentId: definition.id,
              message: 'Duplicate agent id: ${definition.id}',
            ),
          );
        }
        continue;
      }

      final seen = <String>{};
      final resolved = <AgentCatalogEntry>[];
      String? invalid;
      for (final subagentId in definition.subagents) {
        if (!seen.add(subagentId)) {
          invalid = 'Duplicate subagent relation: $subagentId';
          break;
        }
        final target = byId[subagentId];
        if (target == null || duplicateIds.contains(subagentId)) {
          invalid = 'Missing or ambiguous subagent: $subagentId';
          break;
        }
        if (target.isHidden) {
          invalid = 'Hidden subagent: $subagentId';
          break;
        }
        if (target.definition.mode != AgentMode.subagent) {
          invalid = 'Referenced agent is not a subagent: $subagentId';
          break;
        }
        if (_reaches(target.definition, definition.id, byId, <String>{})) {
          invalid = 'Agent relation cycle through: $subagentId';
          break;
        }
        resolved.add(target);
      }
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
