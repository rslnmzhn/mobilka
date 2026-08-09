class ChatStreamEvent {
  const ChatStreamEvent({
    this.delta = '',
    this.finishReason,
    this.usage,
    this.isTerminal = false,
  });

  final String delta;
  final String? finishReason;
  final ChatUsage? usage;
  final bool isTerminal;
}

class ChatUsage {
  const ChatUsage({this.promptTokens, this.completionTokens, this.totalTokens});

  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;

  factory ChatUsage.fromJson(Map<dynamic, dynamic> json) => ChatUsage(
    promptTokens: json['prompt_tokens'] as int?,
    completionTokens: json['completion_tokens'] as int?,
    totalTokens: json['total_tokens'] as int?,
  );
}
