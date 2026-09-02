import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'windows_msi_provenance.dart';
import 'android_updater_bridge.dart';
import 'update_platform_bridge.dart';

const mobilkaWindowsSignerSha256 =
    '84EFAEE8B51EF463E312FC90D8B86613739961F11B0C6582B472BB3845D21BA4';

typedef WindowsProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);
typedef WindowsDetachedProcessLauncher =
    Future<void> Function(String executable, List<String> arguments);

class WindowsMsiInstallHandoff {
  const WindowsMsiInstallHandoff({
    required this.exitRequired,
    required this.restartOnSuccess,
  });

  final bool exitRequired;
  final bool restartOnSuccess;
}

class WindowsMsiUpdateException implements Exception {
  const WindowsMsiUpdateException(this.message);

  final String message;

  @override
  String toString() => 'WindowsMsiUpdateException: $message';
}

class WindowsMsiUpdateBridge {
  WindowsMsiUpdateBridge({
    WindowsProcessRunner? runProcess,
    WindowsDetachedProcessLauncher? launchDetached,
    String? executablePath,
    int? processId,
    bool? isWindows,
    MethodChannel? stagingChannel,
  }) : _runProcess = runProcess ?? _defaultRunProcess,
       _launchDetached = launchDetached ?? _defaultLaunchDetached,
       _executablePath = executablePath ?? Platform.resolvedExecutable,
       _processId = processId ?? pid,
       _isWindows = isWindows ?? Platform.isWindows,
       _stagingChannel =
           stagingChannel ??
           const MethodChannel('com.rslnmzhn.mobilka/windows_updater_staging');

  final WindowsProcessRunner _runProcess;
  final WindowsDetachedProcessLauncher _launchDetached;
  final String _executablePath;
  final int _processId;
  final bool _isWindows;
  final MethodChannel _stagingChannel;

  Future<WindowsMsiProvenanceDecision> inspectProvenance() async {
    if (!_isWindows) {
      return const WindowsMsiProvenanceDecision.denied(
        WindowsMsiProvenanceDenial.missingMarker,
      );
    }
    final result = await _runPowerShell(['-Mode', 'Provenance']);
    final marker = result.exitCode == 0
        ? WindowsMsiProvenance.parseRegistryOutput(result.stdout.toString())
        : null;
    return evaluateWindowsMsiProvenance(
      marker: marker,
      executablePath: _executablePath,
    );
  }

  /// Starts a detached handoff. The Flutter caller must terminate promptly when
  /// [WindowsMsiInstallHandoff.exitRequired] is true.
  Future<WindowsMsiInstallHandoff> apply(
    String basename, {
    required String updatesRoot,
    required int expectedSize,
    required String expectedSha256,
    required String identityToken,
  }) async {
    if (!_isWindows) {
      throw const WindowsMsiUpdateException(
        'Windows MSI updates are unavailable',
      );
    }
    final provenance = await inspectProvenance();
    if (!provenance.allowed) {
      throw WindowsMsiUpdateException(
        'MSI installation provenance was not proven: ${provenance.denial?.name}',
      );
    }

    final signature = await _runPowerShell([
      '-Mode',
      'Verify',
      '-UpdatesRoot',
      updatesRoot,
      '-Basename',
      basename,
      '-ExpectedSize',
      expectedSize.toString(),
      '-ExpectedSha256',
      expectedSha256,
      '-IdentityToken',
      identityToken,
    ]);
    if (signature.exitCode != 0 || !_isVerifiedOutput(signature.stdout)) {
      throw const WindowsMsiUpdateException(
        'MSI Authenticode signature or signer fingerprint is invalid',
      );
    }

    final trusted = await _stagingChannel.invokeMapMethod<String, Object?>(
      'getTrustedSystemPaths',
    );
    final powershell = trusted?['powershell'] as String?;
    if (powershell == null) {
      throw const WindowsMsiUpdateException('Trusted system paths unavailable');
    }
    await _launchDetached(powershell, [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-File',
      _updateScriptPath,
      '-Mode',
      'Handoff',
      '-UpdatesRoot',
      updatesRoot,
      '-Basename',
      basename,
      '-ExpectedSize',
      expectedSize.toString(),
      '-ExpectedSha256',
      expectedSha256,
      '-IdentityToken',
      identityToken,
      '-AppPid',
      _processId.toString(),
      '-AppPath',
      _executablePath,
    ]);
    return const WindowsMsiInstallHandoff(
      exitRequired: true,
      restartOnSuccess: true,
    );
  }

  Future<List<SafeStagedFile>> safeListUpdates(String root) async {
    final values = await _stagingChannel.invokeListMethod<Object?>('safeList', {
      'updatesRoot': root,
    });
    return (values ?? const <Object?>[])
        .map(
          (item) =>
              SafeStagedFile.fromMap(Map<String, Object?>.from(item! as Map)),
        )
        .toList(growable: false);
  }

  Future<void> safeDeleteUpdate(
    String root,
    VerifiedStagedFileIdentity file,
  ) async {
    final current = await verifyStaged(
      root,
      file.basename,
      file.size,
      file.sha256,
      identityToken: file.identityToken,
    );
    if (current == null) return;
    await _stagingChannel.invokeMethod<void>('delete', {
      'updatesRoot': root,
      'basename': file.basename,
      'identityToken': file.identityToken,
      'expectedSize': file.size,
      'expectedSha256': file.sha256,
    });
  }

  Future<VerifiedStagedFileIdentity> importVerified(
    String root,
    String partialName,
    String basename,
    int size,
    String sha256,
  ) async {
    final result = await _stagingChannel
        .invokeMapMethod<String, Object?>('finalizeUpdate', {
          'updatesRoot': root,
          'partialName': partialName,
          'basename': basename,
          'expectedSize': size,
          'expectedSha256': sha256,
        });
    if (result == null) {
      throw const WindowsMsiUpdateException('Safe update import failed');
    }
    return _identityFromMap(result);
  }

  Future<SafeDownloadSink> beginDownload(
    String root,
    String partialName,
  ) async {
    final session = await _stagingChannel.invokeMethod<String>(
      'beginDownload',
      {'updatesRoot': root, 'basename': partialName},
    );
    if (session == null) {
      throw const WindowsMsiUpdateException('Safe partial creation failed');
    }
    return _WindowsDownloadSink(_stagingChannel, session);
  }

  Future<VerifiedStagedFileIdentity?> verifyStaged(
    String root,
    String basename,
    int size,
    String sha256, {
    String? identityToken,
  }) async {
    final result = await _stagingChannel
        .invokeMapMethod<String, Object?>('verifyUpdate', {
          'updatesRoot': root,
          'basename': basename,
          'expectedSize': size,
          'expectedSha256': sha256,
          'identityToken': ?identityToken,
        });
    return result == null ? null : _identityFromMap(result);
  }

  Future<void> rotateLog(String updatesRoot) async {
    final result = await _runPowerShell([
      '-Mode',
      'RotateLog',
      '-UpdatesRoot',
      updatesRoot,
    ]);
    if (result.exitCode != 0) {
      throw const WindowsMsiUpdateException('Could not rotate handoff log');
    }
  }

  Future<ProcessResult> _runPowerShell(List<String> scriptArguments) async {
    return _runProcess(await _trustedPowerShell(), [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-File',
      _updateScriptPath,
      ...scriptArguments,
    ]);
  }

  Future<String> _trustedPowerShell() async {
    final trusted = await _stagingChannel.invokeMapMethod<String, Object?>(
      'getTrustedSystemPaths',
    );
    final powershell = trusted?['powershell'];
    if (powershell is! String || powershell.isEmpty) {
      throw const WindowsMsiUpdateException('Trusted system paths unavailable');
    }
    return powershell;
  }

  String get _updateScriptPath =>
      '${File(_executablePath).parent.path}${Platform.pathSeparator}mobilka_update.ps1';

  static bool _isVerifiedOutput(Object stdout) {
    try {
      final decoded = jsonDecode(stdout.toString());
      return decoded is Map<String, dynamic> && decoded['Status'] == 'Valid';
    } on FormatException {
      return false;
    }
  }

  static VerifiedStagedFileIdentity _identityFromMap(Map value) {
    return VerifiedStagedFileIdentity(
      basename: value['basename'] as String,
      size: value['size'] as int,
      sha256: value['sha256'] as String,
      identityToken: value['identityToken'] as String,
    );
  }

  static Future<ProcessResult> _defaultRunProcess(
    String executable,
    List<String> arguments,
  ) => Process.run(executable, arguments, runInShell: false);

  static Future<void> _defaultLaunchDetached(
    String executable,
    List<String> arguments,
  ) async {
    await Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
  }
}

class _WindowsDownloadSink implements SafeDownloadSink {
  _WindowsDownloadSink(this.channel, this.session);
  final MethodChannel channel;
  final String session;
  bool _closed = false;

  @override
  Future<void> write(List<int> chunk) => channel.invokeMethod<void>(
    'writeDownload',
    {'session': session, 'chunk': Uint8List.fromList(chunk)},
  );

  @override
  Future<void> finish() async {
    if (_closed) return;
    await channel.invokeMethod<void>('finishDownload', {'session': session});
    _closed = true;
  }

  @override
  Future<void> abort() async {
    if (_closed) return;
    await channel.invokeMethod<void>('abortDownload', {'session': session});
    _closed = true;
  }
}
