import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PowerShell helper enforces direct no-reparse bounded operations', () {
    final source = File(
      '.github/windows/mobilka_update.ps1',
    ).readAsStringSync();
    expect(source, contains('ReparsePoint'));
    expect(
      RegExp(r'-LiteralPath').allMatches(source).length,
      greaterThanOrEqualTo(6),
    );
    expect(source, contains('Get-SafeRoot'));
    expect(source, contains('Get-SafeChild'));
    expect(
      source,
      contains(r'$child.Directory.FullName -ine $rootItem.FullName'),
    );
    expect(source, contains('262144'));
    expect(source, contains(r'"$log.1"'));
    expect(source, isNot(contains('-Recurse')));
    expect(source, isNot(contains('Remove-Item -Path')));
    expect(source, isNot(contains('Get-ChildItem')));
    expect(
      source,
      contains('Get-VerifiedMsi \$UpdatesRoot \$Basename \$IdentityToken'),
    );
    expect(
      RegExp(
        r'Get-VerifiedMsi \$UpdatesRoot \$Basename \$IdentityToken',
      ).allMatches(source).length,
      greaterThanOrEqualTo(2),
    );
    expect(source, isNot(contains(r'verified=$verifiedPath')));
    expect(source, isNot(contains('ToHexString')));
    expect(source, contains('[BitConverter]::ToString'));
    expect(source, contains("'ElevatedInstall'"));
    expect(source, contains('SHGetKnownFolderPath'));
    expect(source, contains('GetSystemDirectoryW'));
    expect(source, contains('GetFileIdentity'));
    expect(source, contains('BY_HANDLE_FILE_INFORMATION'));
    expect(source, contains('FILE_FLAG_OPEN_REPARSE_POINT'));
    expect(
      source,
      contains('String.Format(CultureInfo.InvariantCulture, "{0}:{1}:{2}"'),
    );
    expect(source, contains("throw 'Expected MSI identity is required.'"));
    expect(source, contains("throw 'Update identity changed.'"));
    expect(source, contains("'-IdentityToken',\$IdentityToken,'-HandoffId'"));
    expect(source, contains('SetAccessRuleProtection(true, false)'));
    expect(source, contains('BuiltinAdministratorsSid'));
    expect(source, contains('LocalSystemSid'));
    expect(source, contains('VerifyAcl'));
    expect(source, contains(r'Get-AuthenticodeSignature -LiteralPath $copy'));
    expect(source, contains('Protected copy hash mismatch'));
    expect(source, isNot(contains(r'[string]$MsiExecPath')));
    final elevated = source.substring(source.indexOf("'ElevatedInstall' {"));
    expect(elevated, isNot(contains('Write-SafeLog')));
    expect(elevated, isNot(contains(r'Start-Process -FilePath $AppPath')));
    expect(source, isNot(contains(r'$env:TEMP')));
    expect(source, contains("'handoff.log'"));
  });

  test(
    'Android source pins cache updates and uses NOFOLLOW identity checks',
    () {
      final source = File(
        'android/app/src/main/kotlin/com/rslnmzhn/mobilka/MainActivity.kt',
      ).readAsStringSync();
      expect(source, contains('File(cacheDir, UPDATES_DIRECTORY)'));
      expect(source, contains('LinkOption.NOFOLLOW_LINKS'));
      expect(source, contains('Files.isSymbolicLink'));
      expect(source, contains('candidate.parent != root'));
      expect(source, contains('before.fileKey() != again.fileKey()'));
      expect(source, contains('Files.newDirectoryStream(root)'));
      expect(source, isNot(contains('walkFileTree')));
    },
  );

  test('Windows runner exposes native no-follow handle staging authority', () {
    final source = File(
      'windows/runner/updater_staging.cpp',
    ).readAsStringSync();
    expect(source, contains('FILE_FLAG_OPEN_REPARSE_POINT'));
    expect(source, contains('GetFileInformationByHandle'));
    expect(source, contains('nNumberOfLinks == 1'));
    expect(source, contains('CREATE_NEW'));
    expect(source, contains('SetFileInformationByHandle'));
    expect(source, contains('FILE_ATTRIBUTE_REPARSE_POINT'));
    expect(source, contains('SafeName'));
    expect(source, contains('ValidateComponents'));
    expect(source, contains('FILE_READ_ATTRIBUTES'));
    expect(
      source.indexOf('#include <windows.h>'),
      lessThan(source.indexOf('#include <bcrypt.h>')),
    );
    expect(source, contains('FILE_FLAG_BACKUP_SEMANTICS'));
    expect(source, contains('OPEN_EXISTING, true'));
    expect(source, contains('beginDownload'));
    expect(source, contains('writeDownload'));
    expect(source, contains('finishDownload'));
    expect(source, contains('abortDownload'));
    expect(
      source,
      contains('std::map<std::string, std::unique_ptr<DownloadSession>>'),
    );
    expect(source, contains('WriteFile'));
    expect(source, contains('BCryptHashData'));
    expect(source, contains('FlushFileBuffers'));
    expect(source, contains('MultiByteToWideChar'));
    expect(source, contains('WideCharToMultiByte'));
    expect(source, contains('safeList'));
    expect(source, contains('HashHandle'));
    expect(source, contains('identityToken'));
    expect(source, contains('method == "verifyUpdate"'));
    expect(source, contains('method == "finalizeUpdate"'));
    expect(source, contains('FileRenameInfo'));
    expect(source, contains('partial != name + L".part"'));
    expect(source, contains('IsMsiName(name, true)'));
  });

  test('Android cleanup resolver accepts APK parts only for cleanup', () {
    final source = File(
      'android/app/src/main/kotlin/com/rslnmzhn/mobilka/MainActivity.kt',
    ).readAsStringSync();
    expect(
      source,
      contains('requireUpdatePath(rawPath: String?, allowPartial: Boolean)'),
    );
    expect(source, contains('allowPartial && lowerName.endsWith(".apk.part")'));
    expect(source, contains('requireUpdatePath(name, true)'));
    expect(source, contains('requireUpdatePath(rawPath, false)'));
    expect(source, contains('LinkOption.NOFOLLOW_LINKS'));
  });

  test('Windows handoff does not restart after elevated failure', () {
    final source = File(
      '.github/windows/mobilka_update.ps1',
    ).readAsStringSync();
    final handoff = source.substring(
      source.indexOf("'Handoff' {"),
      source.indexOf("'ElevatedInstall' {"),
    );
    final failure = handoff.indexOf(r'if ($elevated.ExitCode -ne 0');
    final failureExit = handoff.indexOf(r'exit $elevated.ExitCode', failure);
    final restart = handoff.indexOf(
      r'Start-Process -FilePath $AppPath',
      failure,
    );
    expect(failure, greaterThanOrEqualTo(0));
    expect(handoff, isNot(contains(r'$elevated.ExitCode -ne 3010')));
    expect(failureExit, greaterThan(failure));
    expect(restart, greaterThan(failureExit));
  });
}
