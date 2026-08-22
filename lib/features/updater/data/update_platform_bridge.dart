import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/update_release.dart';
import 'android_updater_bridge.dart';
import 'windows_msi_update_bridge.dart';

abstract interface class UpdatePlatformBridge {
  Future<UpdateTarget> target();
  Future<Directory> stagingDirectory();
  Future<bool> isWindowsMsiInstalled();
  Future<void> installWindowsMsi(String path);
  Future<bool> installAndroidApk(String path, UpdateAsset asset);
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
    final support = Platform.isAndroid
        ? await getTemporaryDirectory()
        : await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}updates');
  }

  @override
  Future<bool> isWindowsMsiInstalled() async =>
      Platform.isWindows && (await _windowsBridge.inspectProvenance()).allowed;

  @override
  Future<void> installWindowsMsi(String path) async {
    final handoff = await _windowsBridge.apply(path);
    if (handoff.exitRequired) await SystemNavigator.pop();
  }

  @override
  Future<bool> installAndroidApk(String path, UpdateAsset asset) async {
    final preflight = await _androidBridge.preflightApk(path);
    if (preflight.packageName != asset.applicationId ||
        preflight.versionCode != asset.versionCode) {
      throw const UpdateException(
        'APK identity does not match the signed update manifest',
      );
    }
    final result = await _androidBridge.installApk(path);
    return result == AndroidInstallResult.installerLaunched;
  }
}
