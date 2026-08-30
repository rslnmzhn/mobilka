import 'artifact_file_name.dart';

enum ArtifactRepresentation { md, docx }

/// Canonical, app-internal reference to one authoritative artifact file.
class ArtifactLink {
  const ArtifactLink._(this.artifactId, this.representation);

  static const scheme = 'mobilka-artifact';
  static const maxLength = 256;
  static final RegExp _canonical = RegExp(
    r'^mobilka-artifact:([A-Za-z0-9][A-Za-z0-9-]{0,63})\?representation=(md|docx)$',
  );

  final String artifactId;
  final ArtifactRepresentation representation;

  factory ArtifactLink({
    required String artifactId,
    required ArtifactRepresentation representation,
  }) {
    ArtifactFileName.fromId(artifactId, extension: representation.name);
    return ArtifactLink._(artifactId, representation);
  }

  static ArtifactLink? tryParse(String source) {
    if (source.isEmpty || source.length > maxLength || !_isAscii(source)) {
      return null;
    }
    final match = _canonical.firstMatch(source);
    if (match == null) return null;
    try {
      final link = ArtifactLink(
        artifactId: match.group(1)!,
        representation: ArtifactRepresentation.values.byName(match.group(2)!),
      );
      return link.toString() == source ? link : null;
    } on Object {
      return null;
    }
  }

  /// Claims malformed variants so they can never fall through to an external
  /// launcher.
  static bool claimsScheme(String source) {
    final lower = source.toLowerCase();
    return lower.startsWith(scheme);
  }

  static bool _isAscii(String value) {
    for (final unit in value.codeUnits) {
      if (unit > 0x7f) return false;
    }
    return true;
  }

  @override
  String toString() =>
      '$scheme:$artifactId?representation=${representation.name}';
}
