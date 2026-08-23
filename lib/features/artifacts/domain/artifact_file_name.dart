/// File-system-safe artifact file names derived from internally generated
/// artifact IDs.
///
/// Defense-in-depth against path traversal: even though artifact IDs never
/// originate from user input today, every disk operation revalidates through
/// this type so an unexpected ID can never escape the artifacts directory.
class ArtifactFileName {
  ArtifactFileName._(this.value);

  static final RegExp _pattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{0,63}$');

  /// Validates [id] and returns the corresponding `<id>.md` file name.
  ///
  /// Throws [FormatException] for empty IDs, path separators, traversal
  /// segments (`..`), absolute/drive prefixes, whitespace, control characters,
  /// reserved dots-only names, or excessive length.
  factory ArtifactFileName.fromId(String id) {
    if (!_pattern.hasMatch(id)) {
      throw FormatException('Invalid artifact file identifier');
    }
    return ArtifactFileName._('$id.md');
  }

  final String value;
}
