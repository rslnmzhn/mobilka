class VersionNumber implements Comparable<VersionNumber> {
  const VersionNumber(this.major, this.minor, this.patch, [this.fix = 0]);

  final int major;
  final int minor;
  final int patch;
  final int fix;

  factory VersionNumber.parse(String value) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:_fix(\d+))?$').firstMatch(value);
    if (match == null) throw FormatException('Invalid version: $value');
    return VersionNumber(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      match.group(4) != null ? int.parse(match.group(4)!) : 0,
    );
  }

  @override
  int compareTo(VersionNumber other) {
    final majorResult = major.compareTo(other.major);
    if (majorResult != 0) return majorResult;
    final minorResult = minor.compareTo(other.minor);
    if (minorResult != 0) return minorResult;
    final patchResult = patch.compareTo(other.patch);
    if (patchResult != 0) return patchResult;
    return fix.compareTo(other.fix);
  }
}
