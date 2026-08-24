import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/updater/domain/update_manifest.dart';
import 'package:mobilka/features/updater/domain/update_release.dart';

void main() {
  test('strict manifest selects only the matching Android APK', () {
    final manifest = UpdateManifest.parse(utf8.encode(jsonEncode(_manifest())));

    final release = manifest.select(
      const UpdateTarget(
        platform: UpdatePlatform.android,
        architecture: 'arm64-v8a',
      ),
    );

    expect(release.version, '1.2.3');
    expect(release.asset.format, 'apk');
    expect(release.asset.architecture, 'arm64-v8a');
    // Scaled split-per-ABI code must survive parsing untouched.
    expect(release.asset.versionCode, 1004003);
  });

  test('flat unscaled Android version codes are rejected', () {
    final value = _manifest();
    ((value['assets'] as List).first as Map)['versionCode'] = 1002003;

    expect(
      () => UpdateManifest.parse(utf8.encode(jsonEncode(value))),
      throwsFormatException,
    );
  });

  test('strict manifest rejects unknown fields', () {
    final value = _manifest()..['unexpected'] = true;

    expect(
      () => UpdateManifest.parse(utf8.encode(jsonEncode(value))),
      throwsFormatException,
    );
  });

  test('Windows selection requires a primary MSI installer', () {
    final value = _manifest();
    value['assets'] = [
      _asset(
        platform: 'windows',
        arch: 'x86_64',
        format: 'msi',
        fileName: 'mobilka-v1.2.3-windows-x64.msi',
        installer: false,
      ),
    ];
    expect(
      () => UpdateManifest.parse(utf8.encode(jsonEncode(value))),
      throwsFormatException,
    );
  });
}

Map<String, Object?> _manifest() => {
  'schemaVersion': 1,
  'release': {
    'channel': 'stable',
    'tag': 'v1.2.3',
    'version': '1.2.3',
    'draft': false,
    'prerelease': false,
  },
  'assets': [
    _asset(
      platform: 'android',
      arch: 'arm64-v8a',
      format: 'apk',
      fileName: 'mobilka-v1.2.3-android-arm64-v8a.apk',
    ),
  ],
};

Map<String, Object?> _asset({
  required String platform,
  required String arch,
  required String format,
  required String fileName,
  bool? installer,
}) => {
  'platform': platform,
  'arch': arch,
  'format': format,
  'primary': true,
  'applyMode': platform == 'android' ? 'packageInstaller' : 'msi',
  'install': true,
  // Pinned build_runner cannot parse null-aware elements yet.
  // ignore: use_null_aware_elements
  if (installer != null) 'installer': installer,
  if (platform == 'android') ...{
    'applicationId': 'com.rslnmzhn.mobilka',
    // Scaled per Flutter's split-per-ABI formula: abi*1000 + build number.
    'versionCode': switch (arch) {
      'armeabi-v7a' => 1003003,
      'arm64-v8a' => 1004003,
      'x86_64' => 1006003,
      _ => throw StateError('unexpected arch'),
    },
  },
  'fileName': fileName,
  'size': 4,
  'sha256': '0' * 64,
  'downloadUrl':
      'https://github.com/rslnmzhn/mobilka/releases/download/v1.2.3/$fileName',
};
