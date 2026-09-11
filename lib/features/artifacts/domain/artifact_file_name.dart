/// File-system-safe artifact file names derived from internally generated
/// artifact IDs.
///
/// Defense-in-depth against path traversal: even though artifact IDs never
/// originate from user input today, every disk operation revalidates through
/// this type so an unexpected ID can never escape the artifacts directory.
class ArtifactFileName {
  ArtifactFileName._(this.value);

  static final RegExp _pattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{0,63}$');

  static final RegExp _extensionPattern = RegExp(r'^[a-z0-9]{1,8}$');

  static const _windowsReserved = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };

  /// Validates [id] and returns `<id>.<extension>` (defaults to Markdown).
  ///
  /// Throws [FormatException] for empty IDs, path separators, traversal
  /// segments (`..`), absolute/drive prefixes, whitespace, control characters,
  /// reserved dots-only names, excessive length, or an invalid [extension].
  factory ArtifactFileName.fromId(String id, {String extension = 'md'}) {
    if (!_pattern.hasMatch(id)) {
      throw FormatException('Invalid artifact file identifier');
    }
    final stem = id.split('.').first.toUpperCase();
    if (_windowsReserved.contains(stem)) {
      throw FormatException('Artifact file identifier uses a reserved Windows device name');
    }
    if (!_extensionPattern.hasMatch(extension)) {
      throw FormatException('Invalid artifact file extension');
    }
    return ArtifactFileName._('$id.$extension');
  }

  final String value;
}
