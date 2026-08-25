/// Fixed memory file roles for the Memory 2.0 scheme (roadmap M1).
///
/// - `user.md`     — durable facts about the user; model edits go through the
///                   confirmation flow.
/// - `soul.md`     — base personality; owned by the human, never written by
///                   the model. Falls back to [defaultSoul] when missing/empty.
/// - `memory.md`   — the agent's working notebook; applied instantly without
///                   confirmation and intentionally excluded from the prompt
///                   until the next session/context rebuild.
/// - `personas.yaml` — named personality overlays switched on request.
abstract final class MemoryFiles {
  static const user = 'user.md';
  static const soul = 'soul.md';
  static const memory = 'memory.md';
  static const personas = 'personas.yaml';

  /// Model-writable targets, in confirmation-policy order.
  static const confirmTargets = {user};
  static const instantTargets = {memory};
  static const modelTargets = {...confirmTargets, ...instantTargets};

  /// Legacy -> modern renames applied idempotently at startup.
  /// project_context.md is deliberately dropped (owner decision).
  static const legacyRenames = {
    'user_profile.md': user,
    'system_instructions.md': soul,
    'memory_log.md': memory,
  };

  /// Built-in personality used while soul.md is missing or empty.
  static const defaultSoul =
      '''Ты — mobilka: дружелюбный, точный и осторожный ассистент в личном
рабочем пространстве пользователя. Отвечай на языке пользователя, по делу и
без лишних преамбул. Уважай границы: не выдумывай факты о пользователе, не
раскрывай секреты и всегда показывай, что именно собираешься изменить в его
данных, прежде чем изменить.''';
}
