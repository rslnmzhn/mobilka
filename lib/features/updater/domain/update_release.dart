enum UpdatePlatform { android, windows, unsupported }

class UpdateTarget {
  const UpdateTarget({required this.platform, required this.architecture});

  final UpdatePlatform platform;
  final String architecture;
}

class UpdateAsset {
  const UpdateAsset({
    required this.platform,
    required this.architecture,
    required this.format,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.downloadUri,
    required this.primary,
    required this.applyMode,
    required this.install,
    this.installer,
    this.applicationId,
    this.versionCode,
  });

  final String platform;
  final String architecture;
  final String format;
  final String fileName;
  final int size;
  final String sha256;
  final Uri downloadUri;
  final bool primary;
  final String applyMode;
  final bool install;
  final bool? installer;
  final String? applicationId;
  final int? versionCode;
}

class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.tag,
    required this.asset,
  });

  final String version;
  final String tag;
  final UpdateAsset asset;
}

class StagedUpdate {
  const StagedUpdate({required this.release, required this.path});

  final UpdateRelease release;
  final String path;
}

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => 'UpdateException: $message';
}
