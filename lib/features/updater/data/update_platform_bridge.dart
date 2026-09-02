import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/update_release.dart';
import 'android_updater_bridge.dart';
import 'windows_msi_update_bridge.dart';

abstract interface class UpdatePlatformBridge
    implements StagedUpdateFilesystem {
  Future<UpdateTarget> target();
  Future<Directory> stagingDirectory();
  Future<bool> isWindowsMsiInstalled();
  Future<void> installWindowsMsi(
    String basename,
    int expectedSize,
    String expectedSha256, {
    required String identityToken,
  });
  Future<bool> installAndroidApk(
    String basename,
    UpdateAsset asset, {
    String? identityToken,
  });
  Future<List<SafeStagedFile>> safeListStaged();
  Future<void> safeDeleteStaged(
    String basename,
    int expectedSize,
    String expectedSha256, {
    String? identityToken,
  });
  Future<int?> installedVersionCode();
  Future<void> rotateWindowsHandoffLog();
}

abstract interface class StagedUpdateFilesystem {
  Future<SafeDownloadSink> beginDownload(String partialName);
  Future<VerifiedStagedFileIdentity> importVerifiedDownload(
    String partialName,
    String finalName,
    int expectedSize,
    String expectedSha256,
  );
  Future<VerifiedStagedFileIdentity?> verifyStaged(
    String basename,
    int expectedSize,
    String expectedSha256, {
    String? identityToken,
  });
}

abstract interface class SafeDownloadSink {
  Future<void> write(List<int> chunk);
  Future<void> finish();
  Future<void> abort();
}

class MethodChannelUpdatePlatformBridge implements UpdatePlatformBridge {
  MethodChannelUpdatePlatformBridge({
    WindowsMsiUpdateBridge? windowsBridge,
    AndroidUpdaterBridge? androidBridge,
  }) : _windowsBridge = windowsBridge ?? WindowsMsiUpdateBridge(),
       _androidBridge = androidBridge ?? AndroidUpdaterBridge();

  final WindowsMsiUpdateBridge _windowsBridge;
  final AndroidUpdaterBridge _androidBridge;

  @override
  Future<UpdateTarget> target() async {
    if (!Platform.isAndroid && !Platform.isWindows) {
      return const UpdateTarget(
        platform: UpdatePlatform.unsupported,
        architecture: '',
      );
    }
    final architecture = Platform.isAndroid
        ? (await _androidBridge.getRuntimeInfo()).abi
        : 'x86_64';
    if (architecture.isEmpty) {
      throw const UpdateException(
        'Platform bridge did not report an architecture',
      );
    }
    return UpdateTarget(
      platform: Platform.isAndroid
          ? UpdatePlatform.android
          : UpdatePlatform.windows,
      architecture: architecture,
    );
  }

  @override
  Future<Directory> stagingDirectory() async {
    if (!Platform.isAndroid && !Platform.isWindows) {
      throw const UpdateException('Staging is unsupported on this platform');
    }
    if (Platform.isAndroid) {
      return Directory(await _androidBridge.stagingPath());
    }
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}updates');
  }

  @override
  Future<bool> isWindowsMsiInstalled() async =>
      Platform.isWindows && (await _windowsBridge.inspectProvenance()).allowed;

  @override
  Future<void> installWindowsMsi(
    String basename,
    int expectedSize,
    String expectedSha256, {
    required String identityToken,
  }) async {
    final file = await verifyStaged(
      basename,
      expectedSize,
      expectedSha256,
      identityToken: identityToken,
    );
    if (file == null) throw const UpdateException('Unsafe staged MSI');
    final handoff = await _windowsBridge.apply(
      file.basename,
      updatesRoot: (await stagingDirectory()).path,
      expectedSize: file.size,
      expectedSha256: file.sha256,
      identityToken: file.identityToken,
    );
    if (handoff.exitRequired) await SystemNavigator.pop();
  }

  @override
  Future<bool> installAndroidApk(
    String basename,
    UpdateAsset asset, {
    String? identityToken,
  }) async {
    final file = await verifyStaged(
      basename,
      asset.size,
      asset.sha256,
      identityToken: identityToken,
    );
    if (file == null) throw const UpdateException('Unsafe staged APK');
    final AndroidApkPreflight preflight;
    try {
      preflight = await _androidBridge.preflightApk(file);
    } on PlatformException catch (error) {
      throw UpdateInstallException.fromPlatform(error);
    }
    if (preflight.packageName != asset.applicationId ||
        preflight.versionCode != asset.versionCode) {
      throw const UpdateException(
        'APK identity does not match the signed update manifest',
      );
    }
    final AndroidInstallResult result;
    try {
      result = await _androidBridge.installApk(file);
    } on PlatformException catch (error) {
      throw UpdateInstallException.fromPlatform(error);
    }
    return result == AndroidInstallResult.installerLaunched;
  }

  @override
  Future<List<SafeStagedFile>> safeListStaged() async {
    if (!Platform.isAndroid && !Platform.isWindows) return const [];
    if (Platform.isAndroid) return _androidBridge.safeList();
    return _windowsBridge.safeListUpdates((await stagingDirectory()).path);
  }

  @override
  Future<void> safeDeleteStaged(
    String basename,
    int expectedSize,
    String expectedSha256, {
    String? identityToken,
  }) async {
    if (!Platform.isAndroid && !Platform.isWindows) return;
    final file = await verifyStaged(
      basename,
      expectedSize,
      expectedSha256,
      identityToken: identityToken,
    );
    if (file == null) return;
    if (Platform.isAndroid) return _androidBridge.safeDelete(file);
    await _windowsBridge.safeDeleteUpdate(
      (await stagingDirectory()).path,
      file,
    );
  }

  @override
  Future<VerifiedStagedFileIdentity> importVerifiedDownload(
    String partialName,
    String finalName,
    int expectedSize,
    String expectedSha256,
  ) async {
    if (Platform.isAndroid) {
      return _androidBridge.importVerified(
        partialName,
        finalName,
        expectedSize,
        expectedSha256,
      );
    }
    if (Platform.isWindows) {
      return _windowsBridge.importVerified(
        (await stagingDirectory()).path,
        partialName,
        finalName,
        expectedSize,
        expectedSha256,
      );
    }
    throw const UpdateException('Staging is unsupported on this platform');
  }

  @override
  Future<SafeDownloadSink> beginDownload(String partialName) async {
    if (Platform.isAndroid) {
      return _androidBridge.beginDownload(partialName);
    }
    if (Platform.isWindows) {
      return _windowsBridge.beginDownload(
        (await stagingDirectory()).path,
        partialName,
      );
    }
    throw const UpdateException('Staging is unsupported on this platform');
  }

  @override
  Future<VerifiedStagedFileIdentity?> verifyStaged(
    String basename,
    int expectedSize,
    String expectedSha256, {
    String? identityToken,
  }) async {
    if (!Platform.isAndroid && !Platform.isWindows) return null;
    if (Platform.isAndroid) {
      return _androidBridge.verifyStaged(
        basename,
        expectedSize,
        expectedSha256,
        identityToken: identityToken,
      );
    }
    return _windowsBridge.verifyStaged(
      (await stagingDirectory()).path,
      basename,
      expectedSize,
      expectedSha256,
      identityToken: identityToken,
    );
  }

  @override
  Future<int?> installedVersionCode() async => Platform.isAndroid
      ? (await _androidBridge.getRuntimeInfo()).versionCode
      : null;

  @override
  Future<void> rotateWindowsHandoffLog() async {
    if (Platform.isWindows) {
      await _windowsBridge.rotateLog((await stagingDirectory()).path);
    }
  }
}

class VerifiedStagedFileIdentity {
  const VerifiedStagedFileIdentity({
    required this.basename,
    required this.size,
    required this.sha256,
    required this.identityToken,
  });
  final String basename;
  final int size;
  final String sha256;
  final String identityToken;
}

enum UpdateInstallFailure { providerScopeUnavailable, native }

class UpdateInstallException implements Exception {
  const UpdateInstallException(this.failure);

  factory UpdateInstallException.fromPlatform(PlatformException error) =>
      UpdateInstallException(
        error.code == 'providerScopeUnavailable'
            ? UpdateInstallFailure.providerScopeUnavailable
            : UpdateInstallFailure.native,
      );

  final UpdateInstallFailure failure;

  @override
  String toString() => 'UpdateInstallException(${failure.name})';
}
