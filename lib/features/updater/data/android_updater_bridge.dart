import 'dart:io';

import 'package:flutter/services.dart';
import 'update_platform_bridge.dart';

class AndroidUpdaterBridge {
  AndroidUpdaterBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.rslnmzhn.mobilka/updater';

  final MethodChannel _channel;

  Future<String> stagingPath() async =>
      (await _channel.invokeMethod<String>('getStagingPath'))!;

  Future<List<SafeStagedFile>> safeList() async {
    final values = await _channel.invokeListMethod<Object?>('safeListUpdates');
    return (values ?? const <Object?>[])
        .map(
          (value) =>
              SafeStagedFile.fromMap(Map<String, Object?>.from(value! as Map)),
        )
        .toList(growable: false);
  }

  Future<void> safeDelete(VerifiedStagedFileIdentity file) =>
      _channel.invokeMethod<void>('safeDeleteUpdate', _identityMap(file));

  Future<VerifiedStagedFileIdentity> importVerified(
    String partialName,
    String finalName,
    int size,
    String sha256,
  ) async => _identity(
    await _channel.invokeMapMethod<String, Object?>('importVerifiedDownload', {
      'partialName': partialName,
      'basename': finalName,
      'expectedSize': size,
      'expectedSha256': sha256,
    }),
  );

  Future<SafeDownloadSink> beginDownload(String partialName) async {
    final path = (await _channel.invokeMethod<String>('createDownloadPart', {
      'partialName': partialName,
    }))!;
    return _AndroidDownloadSink(File(path));
  }

  Future<VerifiedStagedFileIdentity?> verifyStaged(
    String basename,
    int size,
    String sha256, {
    String? identityToken,
  }) async {
    final value = await _channel
        .invokeMapMethod<String, Object?>('verifyStaged', {
          'basename': basename,
          'expectedSize': size,
          'expectedSha256': sha256,
          'identityToken': identityToken,
        });
    return value == null ? null : _identity(value);
  }

  Future<AndroidUpdaterRuntimeInfo> getRuntimeInfo() async {
    final value = await _channel.invokeMapMethod<String, Object?>(
      'getRuntimeInfo',
    );
    return AndroidUpdaterRuntimeInfo.fromMap(_requireMap(value));
  }

  Future<AndroidApkPreflight> preflightApk(
    VerifiedStagedFileIdentity file,
  ) async {
    final value = await _channel.invokeMapMethod<String, Object?>(
      'preflightApk',
      _identityMap(file),
    );
    return AndroidApkPreflight.fromMap(_requireMap(value));
  }

  Future<AndroidInstallResult> installApk(
    VerifiedStagedFileIdentity file,
  ) async {
    final value = await _channel.invokeMapMethod<String, Object?>(
      'installApk',
      _identityMap(file),
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

  static Map<String, Object?> _identityMap(VerifiedStagedFileIdentity file) => {
    'basename': file.basename,
    'expectedSize': file.size,
    'expectedSha256': file.sha256,
    'identityToken': file.identityToken,
  };
  static VerifiedStagedFileIdentity _identity(Map<String, Object?>? value) {
    final map = _requireMap(value);
    return VerifiedStagedFileIdentity(
      basename: map['basename']! as String,
      size: map['size']! as int,
      sha256: map['sha256']! as String,
      identityToken: map['identityToken']! as String,
    );
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

class _AndroidDownloadSink implements SafeDownloadSink {
  _AndroidDownloadSink(this.file);
  final File file;
  IOSink? _sink;
  IOSink get _output => _sink ??= file.openWrite(mode: FileMode.append);
  @override
  Future<void> write(List<int> chunk) async => _output.add(chunk);
  @override
  Future<void> finish() async {
    await _output.flush();
    await _output.close();
    _sink = null;
  }

  @override
  Future<void> abort() async {
    await _sink?.close();
    _sink = null;
    if (await file.exists()) await file.delete();
  }
}

class SafeStagedFile {
  const SafeStagedFile({
    required this.basename,
    required this.size,
    required this.modifiedMillis,
    this.sha256 = '',
    this.identityToken = '',
  });

  factory SafeStagedFile.fromMap(Map<String, Object?> map) => SafeStagedFile(
    basename: map['basename']! as String,
    size: map['size']! as int,
    modifiedMillis: map['modifiedMillis']! as int,
    sha256: map['sha256'] as String? ?? '',
    identityToken: map['identityToken'] as String? ?? '',
  );

  final String basename;
  final int size;
  final int modifiedMillis;
  final String sha256;
  final String identityToken;
}
