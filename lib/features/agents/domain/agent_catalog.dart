import 'agent_definition.dart';

enum AgentOrigin { bundled, user }

class AgentCatalogEntry {
  const AgentCatalogEntry({
    required this.definition,
    required this.origin,
    required this.location,
    required this.isHidden,
    required this.isFavorite,
  });

  final AgentDefinition definition;
  final AgentOrigin origin;
  final String location;
  final bool isHidden;
  final bool isFavorite;

  bool get isSelectable => !isHidden && definition.mode == AgentMode.primary;
}

class AgentDiscoveryIssue {
  const AgentDiscoveryIssue({required this.location, required this.message});

  final String location;
  final String message;
}

class AgentCatalog {
  const AgentCatalog({
    required this.agents,
    required this.issues,
    required this.selectedId,
  });

  final List<AgentCatalogEntry> agents;
  final List<AgentDiscoveryIssue> issues;
  final String? selectedId;

  AgentCatalogEntry? get selected {
    final id = selectedId;
    if (id == null) return null;
    return agents.where((agent) => agent.definition.id == id).firstOrNull;
  }
}

class AgentDocument {
  const AgentDocument({
    required this.definition,
    required this.origin,
    required this.location,
  });

  final AgentDefinition definition;
  final AgentOrigin origin;
  final String location;
}

class AgentDiscoveryResult {
  const AgentDiscoveryResult({required this.documents, required this.issues});

  final List<AgentDocument> documents;
  final List<AgentDiscoveryIssue> issues;
}
