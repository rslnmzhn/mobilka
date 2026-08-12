enum AgentMode { primary, subagent }

class AgentDefinition {
  const AgentDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.mode,
    required this.prompt,
    this.modelPreference,
    this.subagents = const [],
    this.tools = const [],
    this.isHidden = false,
    this.isFavorite = false,
  });

  /// Stable identifier used by agent and delegation references.
  final String id;
  final String name;
  final String description;
  final AgentMode mode;
  final String? modelPreference;
  final List<String> subagents;
  final List<String> tools;
  final bool isHidden;
  final bool isFavorite;

  /// Markdown after the closing frontmatter delimiter, preserved verbatim.
  final String prompt;
}
