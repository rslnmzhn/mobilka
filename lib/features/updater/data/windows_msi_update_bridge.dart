import 'dart:convert';
import 'dart:io';

import 'windows_msi_provenance.dart';

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
    String? systemRoot,
    bool? isWindows,
  }) : _runProcess = runProcess ?? _defaultRunProcess,
       _launchDetached = launchDetached ?? _defaultLaunchDetached,
       _executablePath = executablePath ?? Platform.resolvedExecutable,
       _processId = processId ?? pid,
       _systemRoot = systemRoot ?? Platform.environment['SystemRoot'] ?? '',
       _isWindows = isWindows ?? Platform.isWindows;

  final WindowsProcessRunner _runProcess;
  final WindowsDetachedProcessLauncher _launchDetached;
  final String _executablePath;
  final int _processId;
  final String _systemRoot;
  final bool _isWindows;

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
  Future<WindowsMsiInstallHandoff> apply(String msiPath) async {
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

    final msi = File(msiPath);
    if (!msiPath.toLowerCase().endsWith('.msi') || !await msi.exists()) {
      throw const WindowsMsiUpdateException(
        'Update is not an existing MSI file',
      );
    }
    final canonicalMsiPath = await msi.resolveSymbolicLinks();
    final signature = await _runPowerShell([
      '-Mode',
      'Verify',
      '-MsiPath',
      canonicalMsiPath,
    ]);
    if (signature.exitCode != 0 || !_isVerifiedOutput(signature.stdout)) {
      throw const WindowsMsiUpdateException(
        'MSI Authenticode signature or signer fingerprint is invalid',
      );
    }

    final powershell = _systemExecutable(
      r'System32\WindowsPowerShell\v1.0\powershell.exe',
    );
    final msiexec = _systemExecutable(r'System32\msiexec.exe');
    await _launchDetached(powershell, [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-File',
      _updateScriptPath,
      '-Mode',
      'Handoff',
      '-MsiPath',
      canonicalMsiPath,
      '-AppPid',
      _processId.toString(),
      '-AppPath',
      _executablePath,
      '-MsiExecPath',
      msiexec,
    ]);
    return const WindowsMsiInstallHandoff(
      exitRequired: true,
      restartOnSuccess: true,
    );
  }

  Future<ProcessResult> _runPowerShell(List<String> scriptArguments) {
    return _runProcess(
      _systemExecutable(r'System32\WindowsPowerShell\v1.0\powershell.exe'),
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-File',
        _updateScriptPath,
        ...scriptArguments,
      ],
    );
  }

  String _systemExecutable(String relativePath) {
    final root = _systemRoot
        .replaceAll('/', r'\')
        .replaceAll(RegExp(r'\\+$'), '');
    if (!RegExp(r'^[A-Za-z]:\\').hasMatch(root)) {
      throw const WindowsMsiUpdateException('Windows system root is invalid');
    }
    return '$root\\$relativePath';
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
