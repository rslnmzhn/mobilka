import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/updater/domain/staged_update_metadata.dart';

void main() {
  final now = DateTime.utc(2026, 8, 30);
  final metadata = StagedUpdateMetadata(
    lifecycle: StagedUpdateLifecycle.verified,
    platform: 'android',
    format: 'apk',
    version: '1.2.3',
    versionCode: 1002003,
    expectedSize: 4,
    sha256: 'a' * 64,
    fileName: 'mobilka-1.2.3-android-arm64_v8a-ab12.apk',
    partialName: 'mobilka-1.2.3-android-arm64_v8a-ab12.apk.part',
    createdAt: now,
    updatedAt: now,
    attemptCount: 0,
    manifestBase64: 'e30=',
    signatureBase64: 'eA==',
  );

  test('strict metadata round trips', () {
    final decoded = StagedUpdateMetadata.tryDecode(metadata.toJson());
    expect(decoded, isNotNull);
    expect(decoded!.fileName, metadata.fileName);
    expect(decoded.versionCode, 1002003);
  });

  test('malformed, forward, and path metadata fail closed', () {
    expect(StagedUpdateMetadata.tryDecode(null), isNull);
    expect(
      StagedUpdateMetadata.tryDecode({
        ...metadata.toJson(),
        'schemaVersion': 3,
      }),
      isNull,
    );
    expect(
      StagedUpdateMetadata.tryDecode({
        ...metadata.toJson(),
        'fileName': '../outside.apk',
      }),
      isNull,
    );
    expect(
      StagedUpdateMetadata.tryDecode({
        ...metadata.toJson(),
        'unexpected': true,
      }),
      isNull,
    );
  });
}
