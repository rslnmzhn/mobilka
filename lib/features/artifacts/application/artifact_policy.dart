import 'dart:convert';

/// Creation/update guardrails for local `.md` artifacts.
///
/// Defaults are intentionally conservative app-sandbox limits; they are plain
/// constants so product decisions can tune them without behavior changes.
abstract final class ArtifactPolicy {
  static const maxTitleLength = 120;
  static const maxContentBytes = 2 * 1024 * 1024;
  static const maxDocuments = 100;
  static const maxTotalBytes = 10 * 1024 * 1024;

  /// Throws [ArtifactPolicyException] when [title]/[content] violate
  /// per-document limits.
  static void validateDocument(String title, String content) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      throw const ArtifactPolicyException('artifacts.errorTitleRequired');
    }
    if (trimmed.length > maxTitleLength) {
      throw const ArtifactPolicyException('artifacts.errorTitleTooLong');
    }
    if (utf8.encode(content).length > maxContentBytes) {
      throw const ArtifactPolicyException('artifacts.errorContentTooLarge');
    }
  }

  /// Throws [ArtifactPolicyException] when storing a document would exceed
  /// aggregate quotas. Callers pass the post-change values: [documentCount]
  /// including the new/updated document, and [totalBytes] covering every
  /// stored document after the write (the replaced version already excluded).
  static void validateQuotas({
    required int documentCount,
    required int totalBytes,
  }) {
    if (documentCount > maxDocuments) {
      throw const ArtifactPolicyException('artifacts.errorQuotaDocuments');
    }
    if (totalBytes > maxTotalBytes) {
      throw const ArtifactPolicyException('artifacts.errorQuotaStorage');
    }
  }

  static int bytesOf(String content) => utf8.encode(content).length;
}

class ArtifactPolicyException implements Exception {
  const ArtifactPolicyException(this.messageKey);

  final String messageKey;

  @override
  String toString() => messageKey;
}
