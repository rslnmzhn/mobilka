import 'dart:convert';

import 'prompt_guard.dart';

class SkillCandidateValidation {
  const SkillCandidateValidation({required this.warnings});

  final List<String> warnings;
}

class SkillContentPolicy {
  const SkillContentPolicy({this.maxBytes = 16 * 1024});

  final int maxBytes;

  static const requiredSections = [
    'Trigger',
    'Procedure',
    'Validate',
    'Fallbacks',
    'Safety',
  ];

  SkillCandidateValidation validate(String content) {
    if (content.trim().isEmpty) {
      throw const FormatException('Skill content is empty');
    }
    if (utf8.encode(content).length > maxBytes) {
      throw const FormatException('Skill exceeds the 16 KiB candidate limit');
    }
    if (content.contains('<untrusted_public_source>') ||
        content.contains('</untrusted_public_source>') ||
        content.contains('<untrusted_skill_data>') ||
        content.contains('</untrusted_skill_data>')) {
      throw const FormatException('Raw public-source blocks are prohibited');
    }
    for (final section in requiredSections) {
      if (!RegExp(
        '^#{1,3} ${RegExp.escape(section)}\\s*\$',
        multiLine: true,
      ).hasMatch(content)) {
        throw FormatException('Missing required section: $section');
      }
    }
    if (_obviousSecret.hasMatch(content)) {
      throw const FormatException('Skill appears to contain a secret');
    }
    if (_highEntropyCredential.hasMatch(content)) {
      throw const FormatException('Skill appears to contain a credential');
    }
    if (_oneOffValue.hasMatch(content)) {
      throw const FormatException('Skill contains a one-off observed value');
    }
    final guarded = const PromptGuard().sanitize(content);
    return SkillCandidateValidation(
      warnings: [
        if (guarded.frontmatterStripped) 'frontmatter',
        if (guarded.hasSuspectedInjection) 'suspected_prompt_injection',
      ],
    );
  }

  static final _obviousSecret = RegExp(
    r'(-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|'
    r'\b(?:glpat-[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9_-]{20,}|(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_-]{16,}|github_pat_[A-Za-z0-9_-]{16,})\b|'
    r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b|'
    r'\bbasic\s+[A-Za-z0-9+/]{12,}={0,2}\b|'
    r'https?://[^\s/@:]+:[^\s/@]+@|'
    r'\b(?:api[_-]?key|access[_-]?token|auth[_-]?token|password|passwd|pwd|token|secret|client[_-]?secret)\s*[:=]\s*["'
    ']?[^\\s"'
    ']{8,})',
    caseSensitive: false,
  );
  static final _oneOffValue = RegExp(
    r'\b(?:current time|observed timestamp|текущее время)\s*[:=]\s*\d{1,4}[-/:T]\d',
    caseSensitive: false,
  );
  static final _highEntropyCredential = RegExp(
    r'(?:\bbearer\s+[0-9A-Za-z_./+=-]{12,}|'
    r'\bpassword\s*[:=]\s*["'
    ']?[0-9A-Za-z_./+=-]{8,}|'
    r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\bAIza[0-9A-Za-z_-]{30,}\b|'
    r'\bxox[baprs]-[0-9A-Za-z-]{20,}\b|\bya29\.[0-9A-Za-z_-]{20,}\b)',
    caseSensitive: false,
  );
}
