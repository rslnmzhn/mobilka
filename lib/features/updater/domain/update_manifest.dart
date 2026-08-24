import 'dart:convert';

import 'update_release.dart';

class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.tag,
    required this.assets,
  });

  final String version;
  final String tag;
  final List<UpdateAsset> assets;

  static final _versionPattern = RegExp(r'^\d+\.\d+\.\d+$');
  static final _digestPattern = RegExp(r'^[0-9a-f]{64}$');
  static final _filePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$');

  factory UpdateManifest.parse(List<int> bytes) {
    if (bytes.isEmpty) throw const FormatException('Manifest is empty');
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on Object {
      throw const FormatException('Manifest is not valid UTF-8 JSON');
    }
    final root = _object(decoded, 'manifest');
    _keys(root, const {'schemaVersion', 'release', 'assets'}, 'manifest');
    if (root['schemaVersion'] != 1) {
      throw const FormatException('Unsupported manifest schema');
    }

    final release = _object(root['release'], 'release');
    _keys(release, const {
      'channel',
      'tag',
      'version',
      'draft',
      'prerelease',
    }, 'release');
    final version = _string(release['version'], 'release.version');
    final tag = _string(release['tag'], 'release.tag');
    if (!_versionPattern.hasMatch(version) || tag != 'v$version') {
      throw const FormatException('Invalid stable release version');
    }
    if (release['channel'] != 'stable' ||
        release['draft'] != false ||
        release['prerelease'] != false) {
      throw const FormatException('Manifest is not a stable release');
    }

    final rawAssets = root['assets'];
    if (rawAssets is! List || rawAssets.isEmpty) {
      throw const FormatException('Manifest assets must be a non-empty list');
    }
    final assets = <UpdateAsset>[];
    final names = <String>{};
    for (var index = 0; index < rawAssets.length; index++) {
      final raw = _object(rawAssets[index], 'assets[$index]');
      const required = {
        'platform',
        'arch',
        'format',
        'primary',
        'fileName',
        'size',
        'sha256',
        'downloadUrl',
      };
      final allowed = {
        ...required,
        'installer',
        'applyMode',
        'install',
        'applicationId',
        'versionCode',
      };
      _keys(raw, allowed, 'assets[$index]', required: required);
      final fileName = _string(raw['fileName'], 'asset.fileName');
      final digest = _string(raw['sha256'], 'asset.sha256');
      final size = raw['size'];
      final primary = raw['primary'];
      final installer = raw['installer'];
      final applyMode = _string(raw['applyMode'], 'asset.applyMode');
      final install = raw['install'];
      final uri = Uri.tryParse(
        _string(raw['downloadUrl'], 'asset.downloadUrl'),
      );
      if (!_filePattern.hasMatch(fileName) || !names.add(fileName)) {
        throw const FormatException('Invalid or duplicate asset filename');
      }
      if (size is! int || size <= 0 || size > UpdateLimits.maxInstallerBytes) {
        throw const FormatException('Invalid asset size');
      }
      if (!_digestPattern.hasMatch(digest)) {
        throw const FormatException('Invalid asset SHA-256');
      }
      if (primary is! bool ||
          install is! bool ||
          (installer != null && installer is! bool)) {
        throw const FormatException('Invalid asset flags');
      }
      if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
        throw const FormatException('Invalid asset download URL');
      }
      if (uri.host != 'github.com' ||
          uri.hasPort ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const FormatException('Invalid asset download URL');
      }
      final platform = _string(raw['platform'], 'asset.platform');
      final architecture = _string(raw['arch'], 'asset.arch');
      final format = _string(raw['format'], 'asset.format');
      if (!_allowedAsset(platform, architecture, format, installer as bool?)) {
        throw const FormatException('Unsupported asset target');
      }
      final applicationId = raw['applicationId'];
      final versionCode = raw['versionCode'];
      if (platform == 'android') {
        // Flutter's Gradle plugin scales split-per-ABI APK version codes as
        // <abi code> * 1000 + <pubspec build number>; the signed manifest
        // carries the scaled code per architecture (roadmap item 45-era
        // verifier shares this formula).
        const abiCodes = {
          'armeabi-v7a': 1,
          'arm64-v8a': 2,
          'x86_64': 4,
        };
        final abiCode = abiCodes[architecture];
        final parts = version.split('.').map(int.parse).toList();
        final baseVersionCode =
            parts[0] * 1000000 + parts[1] * 1000 + parts[2];
        final expectedVersionCode = abiCode == null
            ? null
            : abiCode * 1000 + baseVersionCode;
        if (applyMode != 'packageInstaller' ||
            install != true ||
            applicationId != 'com.rslnmzhn.mobilka' ||
            versionCode is! int ||
            versionCode <= 0 ||
            expectedVersionCode == null ||
            versionCode != expectedVersionCode) {
          throw const FormatException('Invalid Android installer metadata');
        }
      } else if (platform == 'windows' && format == 'msi') {
        if (applyMode != 'msi' || install != true || installer != true) {
          throw const FormatException('Invalid Windows installer metadata');
        }
      } else if (applyMode != 'manual' || install != false) {
        throw const FormatException('Invalid manual update metadata');
      }
      assets.add(
        UpdateAsset(
          platform: platform,
          architecture: architecture,
          format: format,
          fileName: fileName,
          size: size,
          sha256: digest,
          downloadUri: uri,
          primary: primary,
          applyMode: applyMode,
          install: install,
          installer: installer,
          applicationId: applicationId as String?,
          versionCode: versionCode as int?,
        ),
      );
    }
    return UpdateManifest(version: version, tag: tag, assets: assets);
  }

  UpdateRelease select(UpdateTarget target) {
    final platform = switch (target.platform) {
      UpdatePlatform.android => 'android',
      UpdatePlatform.windows => 'windows',
      UpdatePlatform.unsupported => throw const UpdateException(
        'Updates are not supported on this platform',
      ),
    };
    final format = target.platform == UpdatePlatform.android ? 'apk' : 'msi';
    final matching = assets.where(
      (asset) =>
          asset.platform == platform &&
          asset.architecture == target.architecture &&
          asset.format == format &&
          asset.primary &&
          (platform != 'windows' || asset.installer == true),
    );
    if (matching.length != 1) {
      throw const UpdateException('No unique installer matches this device');
    }
    return UpdateRelease(version: version, tag: tag, asset: matching.single);
  }

  static Map<String, dynamic> _object(Object? value, String path) {
    if (value is! Map<String, dynamic>) {
      throw FormatException('$path must be an object');
    }
    return value;
  }

  static String _string(Object? value, String path) {
    if (value is! String || value.isEmpty) {
      throw FormatException('$path must be a non-empty string');
    }
    return value;
  }

  static void _keys(
    Map<String, dynamic> value,
    Set<String> allowed,
    String path, {
    Set<String>? required,
  }) {
    if (!allowed.containsAll(value.keys) ||
        !(value.keys.toSet().containsAll(required ?? allowed))) {
      throw FormatException('$path has missing or unknown fields');
    }
  }

  static bool _allowedAsset(
    String platform,
    String architecture,
    String format,
    bool? installer,
  ) =>
      (platform == 'android' &&
          const {'armeabi-v7a', 'arm64-v8a', 'x86_64'}.contains(architecture) &&
          format == 'apk' &&
          installer == null) ||
      (platform == 'windows' &&
          architecture == 'x86_64' &&
          const {'msi', 'zip'}.contains(format) &&
          installer != null) ||
      (platform == 'linux' &&
          architecture == 'x86_64' &&
          const {'appimage', 'zip'}.contains(format) &&
          installer == null);
}

abstract final class UpdateLimits {
  static const maxManifestBytes = 1024 * 1024;
  static const maxSignatureBytes = 1024;
  static const maxReleaseMetadataBytes = 1024 * 1024;
  static const maxInstallerBytes = 2 * 1024 * 1024 * 1024;
  static const maxRedirects = 5;
}
