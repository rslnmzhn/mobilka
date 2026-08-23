/// Provider/model capability flags used to gate vision payloads and tool
/// definitions before requests are sent (roadmap item 45).
class ModelCapabilities {
  const ModelCapabilities({required this.vision, required this.tools});

  final bool vision;
  final bool tools;
}

/// Heuristic resolver over OpenAI-compatible model identifiers.
///
/// Detection is offline and deterministic: no probe requests, no network.
/// Defaults are conservative where a wrong guess produces broken requests:
/// - `vision` is OFF unless the id matches a known multimodal family, because
///   sending image parts to a text-only endpoint fails hard.
/// - `tools` stays ON (current production behavior) unless the id matches a
///   family known not to support function calling; providers that ignore the
///   `tools` field keep working.
abstract final class ModelCapabilityResolver {
  static const _visionPatterns = [
    'gpt-4o',
    'chatgpt-4o',
    'gpt-4-turbo',
    'gpt-4.1',
    'gpt-5',
    'o4-mini',
    'claude-3',
    'claude-4',
    'claude-opus',
    'claude-sonnet',
    'claude-haiku',
    'gemini',
    'llama-3.2-vision',
    'llama3.2-vision',
    'pixtral',
    'qwen-vl',
    'qwen2-vl',
    'qwen2.5-vl',
    'minicpm-v',
    'internvl',
    'molmo',
    'vision',
  ];

  static const _noToolsPatterns = [
    '-gguf',
    'ggml',
    'text-embedding',
    'whisper',
    'tts',
  ];

  static ModelCapabilities resolve(String modelId) {
    final id = modelId.toLowerCase();
    return ModelCapabilities(
      vision: _matchesAny(id, _visionPatterns),
      tools: !_matchesAny(id, _noToolsPatterns),
    );
  }

  static bool _matchesAny(String id, List<String> patterns) =>
      patterns.any(id.contains);
}
