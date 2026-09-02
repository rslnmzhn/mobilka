import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/updater/data/android_updater_bridge.dart';
import 'package:mobilka/features/updater/data/update_platform_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AndroidUpdaterBridge.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('maps runtime information from the native contract', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getRuntimeInfo');
      return <String, Object?>{
        'abi': 'arm64-v8a',
        'supportedAbis': <String>['arm64-v8a', 'armeabi-v7a'],
        'packageName': 'com.rslnmzhn.mobilka',
        'versionCode': 42,
        'signingSha256': 'fingerprint',
      };
    });

    final info = await AndroidUpdaterBridge().getRuntimeInfo();

    expect(info.abi, 'arm64-v8a');
    expect(info.supportedAbis, ['arm64-v8a', 'armeabi-v7a']);
    expect(info.packageName, 'com.rslnmzhn.mobilka');
    expect(info.versionCode, 42);
    expect(info.signingSha256, 'fingerprint');
  });

  test(
    'passes the exact staged identity and maps successful preflight',
    () async {
      const identity = VerifiedStagedFileIdentity(
        basename: 'mobilka-1.2.3-android-arm64-aa.apk',
        size: 12,
        sha256: 'hash',
        identityToken: 'identity',
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'preflightApk');
        expect(call.arguments, {
          'basename': identity.basename,
          'expectedSize': identity.size,
          'expectedSha256': identity.sha256,
          'identityToken': identity.identityToken,
        });
        return <String, Object?>{
          'status': 'ready',
          'packageName': 'com.rslnmzhn.mobilka',
          'versionCode': 43,
          'signingSha256': 'fingerprint',
        };
      });

      final result = await AndroidUpdaterBridge().preflightApk(identity);

      expect(result.packageName, 'com.rslnmzhn.mobilka');
      expect(result.versionCode, 43);
    },
  );

  test('returns a distinct pending-permission install result', () async {
    const identity = VerifiedStagedFileIdentity(
      basename: 'mobilka-1.2.3-android-arm64-aa.apk',
      size: 12,
      sha256: 'hash',
      identityToken: 'identity',
    );
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'installApk');
      expect(call.arguments, {
        'basename': identity.basename,
        'expectedSize': identity.size,
        'expectedSha256': identity.sha256,
        'identityToken': identity.identityToken,
      });
      return <String, Object?>{
        'status': calls++ == 0 ? 'pendingPermission' : 'installerLaunched',
      };
    });

    final bridge = AndroidUpdaterBridge();
    final result = await bridge.installApk(identity);

    expect(result, AndroidInstallResult.pendingPermission);
    expect(
      await bridge.installApk(identity),
      AndroidInstallResult.installerLaunched,
    );
  });

  test('safe staging methods use basenames only', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStagingPath') return '/cache/updates';
      if (call.method == 'safeListUpdates') {
        return <Object?>[
          <String, Object?>{
            'basename': 'mobilka-1.2.3-android-arm64_v8a-ab.apk',
            'size': 12,
            'modifiedMillis': 42,
          },
        ];
      }
      expect(call.method, 'safeDeleteUpdate');
      expect(call.arguments, containsPair('identityToken', 'id'));
      return null;
    });
    final bridge = AndroidUpdaterBridge();
    expect(await bridge.stagingPath(), '/cache/updates');
    expect((await bridge.safeList()).single.size, 12);
    await bridge.safeDelete(
      const VerifiedStagedFileIdentity(
        basename: 'mobilka-1.2.3-android-arm64_v8a-ab.apk',
        size: 12,
        sha256: 'hash',
        identityToken: 'id',
      ),
    );
  });

  test('creates and finalizes only a strict visible part basename', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'createDownloadPart') {
        expect(call.arguments, {
          'partialName': 'mobilka-1.2.3-android-arm64-aa.apk.part',
        });
        return '/cache/updates/mobilka-1.2.3-android-arm64-aa.apk.part';
      }
      expect(call.method, 'importVerifiedDownload');
      expect(
        call.arguments,
        containsPair('partialName', 'mobilka-1.2.3-android-arm64-aa.apk.part'),
      );
      return <String, Object?>{
        'basename': 'mobilka-1.2.3-android-arm64-aa.apk',
        'size': 3,
        'sha256': 'a' * 64,
        'identityToken': 'id',
      };
    });
    final bridge = AndroidUpdaterBridge();
    final sink = await bridge.beginDownload(
      'mobilka-1.2.3-android-arm64-aa.apk.part',
    );
    expect(sink, isA<SafeDownloadSink>());
    final result = await bridge.importVerified(
      'mobilka-1.2.3-android-arm64-aa.apk.part',
      'mobilka-1.2.3-android-arm64-aa.apk',
      3,
      'a' * 64,
    );
    expect(result.basename, endsWith('.apk'));
  });
}
