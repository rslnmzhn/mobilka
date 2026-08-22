import 'dart:convert';

const mobilkaMsiUpgradeCode = 'FDE6F32F-2EFE-5295-A1FA-534DFD36A8A9';

class WindowsMsiProvenance {
  const WindowsMsiProvenance({
    required this.installType,
    required this.installLocation,
    required this.upgradeCode,
  });

  final String installType;
  final String installLocation;
  final String upgradeCode;

  static WindowsMsiProvenance? parseRegistryOutput(String output) {
    if (output.trim().isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(output);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final installType = decoded['InstallType'];
    final installLocation = decoded['InstallLocation'];
    final upgradeCode = decoded['UpgradeCode'];
    if (installType is! String ||
        installLocation is! String ||
        upgradeCode is! String) {
      return null;
    }
    return WindowsMsiProvenance(
      installType: installType,
      installLocation: installLocation,
      upgradeCode: upgradeCode,
    );
  }
}

enum WindowsMsiProvenanceDenial {
  missingMarker,
  wrongInstallType,
  wrongUpgradeCode,
  invalidInstallLocation,
  executableOutsideInstallLocation,
}

class WindowsMsiProvenanceDecision {
  const WindowsMsiProvenanceDecision._(this.allowed, this.denial);

  const WindowsMsiProvenanceDecision.allowed() : this._(true, null);

  const WindowsMsiProvenanceDecision.denied(WindowsMsiProvenanceDenial denial)
    : this._(false, denial);

  final bool allowed;
  final WindowsMsiProvenanceDenial? denial;
}

WindowsMsiProvenanceDecision evaluateWindowsMsiProvenance({
  required WindowsMsiProvenance? marker,
  required String executablePath,
}) {
  if (marker == null) {
    return const WindowsMsiProvenanceDecision.denied(
      WindowsMsiProvenanceDenial.missingMarker,
    );
  }
  if (marker.installType != 'MSI') {
    return const WindowsMsiProvenanceDecision.denied(
      WindowsMsiProvenanceDenial.wrongInstallType,
    );
  }
  if (marker.upgradeCode.toUpperCase() != mobilkaMsiUpgradeCode) {
    return const WindowsMsiProvenanceDecision.denied(
      WindowsMsiProvenanceDenial.wrongUpgradeCode,
    );
  }

  final installLocation = _normalizeAbsoluteWindowsPath(marker.installLocation);
  final executable = _normalizeAbsoluteWindowsPath(executablePath);
  if (installLocation == null) {
    return const WindowsMsiProvenanceDecision.denied(
      WindowsMsiProvenanceDenial.invalidInstallLocation,
    );
  }
  if (executable == null ||
      executable.length == 3 ||
      !executable.toLowerCase().startsWith(
        '${installLocation.toLowerCase()}\\',
      )) {
    return const WindowsMsiProvenanceDecision.denied(
      WindowsMsiProvenanceDenial.executableOutsideInstallLocation,
    );
  }
  return const WindowsMsiProvenanceDecision.allowed();
}

String? _normalizeAbsoluteWindowsPath(String input) {
  var value = input.trim().replaceAll('/', r'\');
  while (value.length > 3 && value.endsWith(r'\')) {
    value = value.substring(0, value.length - 1);
  }
  if (!RegExp(r'^[A-Za-z]:\\').hasMatch(value)) return null;
  if (value.length == 3) return value;
  final segments = value.substring(3).split(r'\');
  if (segments.any(
    (segment) => segment.isEmpty || segment == '.' || segment == '..',
  )) {
    return null;
  }
  return value;
}
