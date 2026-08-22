import 'package:flutter/services.dart';

class AndroidUpdaterBridge {
  AndroidUpdaterBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.rslnmzhn.mobilka/updater';

  final MethodChannel _channel;

  Future<AndroidUpdaterRuntimeInfo> getRuntimeInfo() async {
    final value = await _channel.invokeMapMethod<String, Object?>(
      'getRuntimeInfo',
    );
    return AndroidUpdaterRuntimeInfo.fromMap(_requireMap(value));
  }

  Future<AndroidApkPreflight> preflightApk(String apkPath) async {
    final value = await _channel.invokeMapMethod<String, Object?>(
      'preflightApk',
      {'apkPath': apkPath},
    );
    return AndroidApkPreflight.fromMap(_requireMap(value));
  }

  Future<AndroidInstallResult> installApk(String apkPath) async {
    final value = await _channel.invokeMapMethod<String, Object?>(
      'installApk',
      {'apkPath': apkPath},
    );
    final map = _requireMap(value);
    return switch (map['status']) {
      'pendingPermission' => AndroidInstallResult.pendingPermission,
      'installerLaunched' => AndroidInstallResult.installerLaunched,
      final status => throw FormatException(
        'Unknown Android updater install status: $status',
      ),
    };
  }

  static Map<String, Object?> _requireMap(Map<String, Object?>? value) {
    if (value == null) {
      throw const FormatException('Android updater returned no result');
    }
    return value;
  }
}

class AndroidUpdaterRuntimeInfo {
  const AndroidUpdaterRuntimeInfo({
    required this.abi,
    required this.supportedAbis,
    required this.packageName,
    required this.versionCode,
    required this.signingSha256,
  });

  factory AndroidUpdaterRuntimeInfo.fromMap(Map<String, Object?> map) {
    return AndroidUpdaterRuntimeInfo(
      abi: map['abi']! as String,
      supportedAbis: (map['supportedAbis']! as List<Object?>).cast<String>(),
      packageName: map['packageName']! as String,
      versionCode: map['versionCode']! as int,
      signingSha256: map['signingSha256']! as String,
    );
  }

  final String abi;
  final List<String> supportedAbis;
  final String packageName;
  final int versionCode;
  final String signingSha256;
}

class AndroidApkPreflight {
  const AndroidApkPreflight({
    required this.packageName,
    required this.versionCode,
    required this.signingSha256,
  });

  factory AndroidApkPreflight.fromMap(Map<String, Object?> map) {
    if (map['status'] != 'ready') {
      throw FormatException(
        'Unexpected APK preflight status: ${map['status']}',
      );
    }
    return AndroidApkPreflight(
      packageName: map['packageName']! as String,
      versionCode: map['versionCode']! as int,
      signingSha256: map['signingSha256']! as String,
    );
  }

  final String packageName;
  final int versionCode;
  final String signingSha256;
}

enum AndroidInstallResult { pendingPermission, installerLaunched }
