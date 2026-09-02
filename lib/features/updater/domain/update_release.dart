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
    this.proof,
  });

  final String version;
  final String tag;
  final UpdateAsset asset;

  /// Exact canonical bytes and detached signature authenticated at discovery.
  final StagedUpdateProof? proof;
}

class StagedUpdateProof {
  const StagedUpdateProof({
    required this.manifestBytes,
    required this.signatureBytes,
  });

  final List<int> manifestBytes;
  final List<int> signatureBytes;
}

class StagedUpdate {
  const StagedUpdate({String? id, required this.release, String path = ''})
    : id = id ?? path;

  /// Presentation-only projection identifier. It never authorizes filesystem IO.
  final String id;
  final UpdateRelease release;
}

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => 'UpdateException: $message';
}
