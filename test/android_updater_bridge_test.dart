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

  test('passes the APK path and maps successful preflight', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'preflightApk');
      expect(call.arguments, {'apkPath': '/cache/updates/mobilka.apk'});
      return <String, Object?>{
        'status': 'ready',
        'packageName': 'com.rslnmzhn.mobilka',
        'versionCode': 43,
        'signingSha256': 'fingerprint',
      };
    });

    final result = await AndroidUpdaterBridge().preflightApk(
      '/cache/updates/mobilka.apk',
    );

    expect(result.packageName, 'com.rslnmzhn.mobilka');
    expect(result.versionCode, 43);
  });

  test('returns a distinct pending-permission install result', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'installApk');
      return <String, Object?>{'status': 'pendingPermission'};
    });

    final result = await AndroidUpdaterBridge().installApk(
      '/cache/updates/mobilka.apk',
    );

    expect(result, AndroidInstallResult.pendingPermission);
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
      expect(call.arguments, {
        'basename': 'mobilka-1.2.3-android-arm64_v8a-ab.apk',
      });
      return null;
    });
    final bridge = AndroidUpdaterBridge();
    expect(await bridge.stagingPath(), '/cache/updates');
    expect((await bridge.safeList()).single.size, 12);
    await bridge.safeDelete('mobilka-1.2.3-android-arm64_v8a-ab.apk');
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
