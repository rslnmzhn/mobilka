import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/updater/data/android_updater_bridge.dart';

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
}
