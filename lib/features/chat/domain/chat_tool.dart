enum ChatToolEffect { readOnly, mutating, sensitive, runtimeConfirmed }

class ChatToolDefinition {
  const ChatToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
    this.effect = ChatToolEffect.sensitive,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  final ChatToolEffect effect;

  Map<String, dynamic> toJson() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}
