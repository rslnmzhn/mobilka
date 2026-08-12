enum AgentMode { primary, subagent }

class AgentDefinition {
  AgentDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.mode,
    required this.prompt,
    this.modelPreference,
    List<String> subagents = const [],
    List<String> tools = const [],
  }) : subagents = List.unmodifiable(subagents),
       tools = List.unmodifiable(tools);

  /// Stable identifier used by agent and delegation references.
  final String id;
  final String name;
  final String description;
  final AgentMode mode;
  final String? modelPreference;
  final List<String> subagents;
  final List<String> tools;

  /// Markdown after the closing frontmatter delimiter, preserved verbatim.
  final String prompt;
}
