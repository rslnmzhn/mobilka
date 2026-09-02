enum StagedUpdateLifecycle {
  downloading,
  finalizing,
  verified,
  permissionRequired,
  installerLaunched,
  handoffStarted,
}

class StagedUpdateMetadata {
  const StagedUpdateMetadata({
    required this.lifecycle,
    required this.platform,
    required this.format,
    required this.version,
    required this.expectedSize,
    required this.sha256,
    required this.fileName,
    required this.partialName,
    required this.createdAt,
    required this.updatedAt,
    required this.attemptCount,
    required this.manifestBase64,
    required this.signatureBase64,
    this.fileIdentity,
    this.versionCode,
    this.lastAttemptAt,
  });

  static const schemaVersion = 2;
  static final _namePattern = RegExp(
    r'^mobilka-\d+\.\d+\.\d+-(android|windows)-[A-Za-z0-9_-]+-[0-9a-f]+\.(apk|msi)$',
  );
  static final _hashPattern = RegExp(r'^[0-9a-f]{64}$');
  static final _versionPattern = RegExp(r'^\d+\.\d+\.\d+$');

  final StagedUpdateLifecycle lifecycle;
  final String platform;
  final String format;
  final String version;
  final int? versionCode;
  final int expectedSize;
  final String sha256;
  final String fileName;
  final String partialName;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastAttemptAt;
  final int attemptCount;
  final String manifestBase64;
  final String signatureBase64;
  final String? fileIdentity;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'lifecycle': lifecycle.name,
    'platform': platform,
    'format': format,
    'version': version,
    'versionCode': versionCode,
    'expectedSize': expectedSize,
    'sha256': sha256,
    'fileName': fileName,
    'partialName': partialName,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'lastAttemptAt': lastAttemptAt?.toUtc().toIso8601String(),
    'attemptCount': attemptCount,
    'manifestBase64': manifestBase64,
    'signatureBase64': signatureBase64,
    'fileIdentity': fileIdentity,
  };

  static StagedUpdateMetadata? tryDecode(Object? value) {
    try {
      if (value is! Map || value.length != 17) return null;
      final map = Map<String, Object?>.from(value);
      if (map['schemaVersion'] != schemaVersion) return null;
      final lifecycle = StagedUpdateLifecycle.values.singleWhere(
        (item) => item.name == map['lifecycle'],
      );
      final platform = map['platform'] as String;
      final format = map['format'] as String;
      final version = map['version'] as String;
      final versionCode = map['versionCode'] as int?;
      final expectedSize = map['expectedSize'] as int;
      final sha256 = map['sha256'] as String;
      final fileName = map['fileName'] as String;
      final partialName = map['partialName'] as String;
      final attemptCount = map['attemptCount'] as int;
      final manifestBase64 = map['manifestBase64'] as String;
      final signatureBase64 = map['signatureBase64'] as String;
      final fileIdentity = map['fileIdentity'] as String?;
      final createdAt = DateTime.parse(map['createdAt'] as String).toUtc();
      final updatedAt = DateTime.parse(map['updatedAt'] as String).toUtc();
      final lastRaw = map['lastAttemptAt'];
      final lastAttemptAt = lastRaw == null
          ? null
          : DateTime.parse(lastRaw as String).toUtc();
      final validPlatform = platform == 'android' || platform == 'windows';
      if (!validPlatform ||
          format != (platform == 'android' ? 'apk' : 'msi') ||
          !_versionPattern.hasMatch(version) ||
          (platform == 'android' && (versionCode == null || versionCode < 1)) ||
          (platform == 'windows' && versionCode != null) ||
          expectedSize < 1 ||
          !_hashPattern.hasMatch(sha256) ||
          !_namePattern.hasMatch(fileName) ||
          !fileName.endsWith('.$format') ||
          partialName != '$fileName.part' ||
          attemptCount < 0 ||
          manifestBase64.isEmpty ||
          signatureBase64.isEmpty ||
          updatedAt.isBefore(createdAt) ||
          (lastAttemptAt != null && lastAttemptAt.isBefore(createdAt))) {
        return null;
      }
      return StagedUpdateMetadata(
        lifecycle: lifecycle,
        platform: platform,
        format: format,
        version: version,
        versionCode: versionCode,
        expectedSize: expectedSize,
        sha256: sha256,
        fileName: fileName,
        partialName: partialName,
        createdAt: createdAt,
        updatedAt: updatedAt,
        lastAttemptAt: lastAttemptAt,
        attemptCount: attemptCount,
        manifestBase64: manifestBase64,
        signatureBase64: signatureBase64,
        fileIdentity: fileIdentity,
      );
    } on Object {
      return null;
    }
  }

  StagedUpdateMetadata transition(
    StagedUpdateLifecycle next,
    DateTime now, {
    bool applying = false,
    String? fileIdentity,
  }) => StagedUpdateMetadata(
    lifecycle: next,
    platform: platform,
    format: format,
    version: version,
    versionCode: versionCode,
    expectedSize: expectedSize,
    sha256: sha256,
    fileName: fileName,
    partialName: partialName,
    createdAt: createdAt,
    updatedAt: now.toUtc(),
    lastAttemptAt: applying ? now.toUtc() : lastAttemptAt,
    attemptCount: applying ? attemptCount + 1 : attemptCount,
    manifestBase64: manifestBase64,
    signatureBase64: signatureBase64,
    fileIdentity: fileIdentity ?? this.fileIdentity,
  );
}
