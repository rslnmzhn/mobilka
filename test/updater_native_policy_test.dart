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

  test('Android package declares the exact updater provider scope', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final paths = File(
      'android/app/src/main/res/xml/file_paths.xml',
    ).readAsStringSync();
    expect(manifest, contains('androidx.core.content.FileProvider'));
    expect(manifest, contains(r'${applicationId}.updater.files'));
    expect(manifest, contains('android:resource="@xml/file_paths"'));
    expect(paths, contains('name="updates"'));
    expect(paths, contains('path="updates/"'));
    expect(paths, isNot(contains('path="."')));
  });

  test('Android package visibility is narrow and launch races are handled', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final source = File(
      'android/app/src/main/kotlin/com/rslnmzhn/mobilka/MainActivity.kt',
    ).readAsStringSync();
    expect(manifest, contains('android.intent.action.VIEW'));
    expect(
      manifest,
      contains('android:mimeType="application/vnd.android.package-archive"'),
    );
    expect(manifest, isNot(contains('QUERY_ALL_PACKAGES')));
    expect(source, contains('installIntent.resolveActivity(packageManager)'));
    expect(source, contains('settingsIntent.resolveActivity(packageManager)'));
    expect(
      source,
      contains('import android.content.ActivityNotFoundException'),
    );
    expect(
      RegExp(
        r'catch \(_: ActivityNotFoundException\)',
      ).allMatches(source).length,
      2,
    );
  });

  test('Android Gradle verifier is XXE-safe and checks every variant APK', () {
    final wiring = File('android/app/build.gradle.kts').readAsStringSync();
    final verifier = File(
      'android/buildSrc/src/main/kotlin/UpdaterProviderVerifier.kt',
    ).readAsStringSync();
    expect(wiring, contains('XMLConstants.FEATURE_SECURE_PROCESSING, true'));
    expect(wiring, contains('disallow-doctype-decl'));
    expect(wiring, contains('external-general-entities", false'));
    expect(wiring, contains('external-parameter-entities", false'));
    expect(wiring, contains('load-external-dtd", false'));
    expect(wiring, contains('isXIncludeAware = false'));
    expect(wiring, contains('isExpandEntityReferences = false'));
    expect(wiring, contains('XMLConstants.ACCESS_EXTERNAL_DTD, ""'));
    expect(wiring, contains('XMLConstants.ACCESS_EXTERNAL_SCHEMA, ""'));
    expect(wiring, contains('outputs/apk/\${variant.name}'));
    expect(wiring, contains('walkTopDown()'));
    expect(wiring, contains('variantApks.forEach { apk ->'));
    expect(wiring, contains('package\$variantName'));
    expect(wiring, contains('finalizedBy(verifyPackagedScope)'));
    expect(wiring, contains('aapt2, "dump", "xmltree", apk'));
    expect(verifier, contains('data class PackagedResourceRef'));
    expect(verifier, contains('PackagedResourceRef(id, archivePath)'));
    expect(wiring, contains('dump(apk, filePathsResource.archivePath)'));
    expect(
      wiring,
      contains('build-tools/\${android.buildToolsVersion}'),
    );
    expect(wiring, isNot(contains('dump(apk, "res/xml/file_paths.xml")')));
    expect(wiring, isNot(contains('maxByOrNull { it.name }')));
    expect(wiring, isNot(contains('app-\${variant.name}.apk')));
    expect(wiring, isNot(contains('app-release.apk')));
    expect(verifier, contains('expectRejected("exact resource alias")'));
    expect(verifier, contains('expectRejected("non-XML archive entry")'));
    expect(verifier, contains('expectRejected("duplicate configuration")'));
    expect(
      verifier,
      contains('expectRejected("nested otherwise-valid configuration")'),
    );
    expect(verifier, contains('multipleConfigurations'));
  });

  test(
    'Android install requires final identity and validates provider metadata',
    () {
      final source = File(
        'android/app/src/main/kotlin/com/rslnmzhn/mobilka/MainActivity.kt',
      ).readAsStringSync();
      expect(RegExp(r'allowPartial = false,').allMatches(source).length, 2);
      expect(source, contains('identityToken is required'));
      expect(source, contains('resolveContentProvider(authority'));
      expect(source, contains('pathsResource != R.xml.file_paths'));
      expect(source, contains('ERROR_PROVIDER_SCOPE'));
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
    expect(source, contains('requireUpdatePath(name, allowPartial)'));
    expect(source, contains('allowPartial = false'));
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
