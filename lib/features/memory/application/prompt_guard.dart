import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Result of running memory content through [PromptGuard].
class GuardedContent {
  const GuardedContent({
    required this.content,
    required this.frontmatterStripped,
    required this.suspiciousLines,
  });

  final String content;
  final bool frontmatterStripped;
  final List<String> suspiciousLines;

  bool get hasSuspectedInjection => suspiciousLines.isNotEmpty;
}

/// Hardens memory-sourced text before it enters the system prompt:
/// - YAML frontmatter is stripped (reserved for metadata);
/// - lines matching prompt-injection patterns are marked inline with
///   `[suspected-injection]` so the model treats them with suspicion instead
///   of silently obeying or silently dropping user data.
///
/// No length truncation by design (owner decision).
class PromptGuard {
  const PromptGuard();

  static final _injectionPatterns = [
    RegExp(
      r'игнорир[а-яё]*\s+(все\s+)?(предыдущ[а-яё]+|прошл[а-яё]+)\s+'
      r'(указани[а-яё]*|инструкц[а-яё]*)',
      caseSensitive: false,
    ),
    RegExp(
      r'ignore\s+(all\s+)?(previous|prior|above)\s+(instructions|prompts)',
      caseSensitive: false,
    ),
    RegExp(
      r'(извлеки|получи|укради|выведи|send|exfiltrate)[^.\n]*'
      r'(api[\s_-]?key|[а-яё]*токен[а-яё]*|tokens?|secrets?|ключ[а-яё]*)',
      caseSensitive: false,
    ),
    RegExp(
      r'(ты\s+теперь|you\s+are\s+now)[^.\n]*'
      r'(без\s+ограничений|unrestricted|jailbroken)',
      caseSensitive: false,
    ),
  ];

  static final _frontmatter = RegExp(
    r'^---\r?\n.*?\r?\n---\r?\n?',
    dotAll: true,
  );

  /// Applies frontmatter stripping and inline injection marking.
  GuardedContent sanitize(String content) {
    var working = content;
    var stripped = false;
    if (working.trimLeft().startsWith('---')) {
      final without = working.replaceFirstMapped(_frontmatter, (_) => '');
      if (without != working) {
        working = without;
        stripped = true;
      }
    }

    final flagged = <String>[];
    final lines = working.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (_injectionPatterns.any((p) => p.hasMatch(lines[i]))) {
        flagged.add(lines[i]);
        lines[i] = '[suspected-injection] ${lines[i]}';
      }
    }
    return GuardedContent(
      content: lines.join('\n'),
      frontmatterStripped: stripped,
      suspiciousLines: flagged,
    );
  }
}

final promptGuardProvider = Provider<PromptGuard>((ref) => const PromptGuard());
