import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/updater/data/update_platform_bridge.dart';
import 'package:mobilka/features/updater/data/windows_msi_update_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.rslnmzhn.mobilka/windows_updater_staging');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('native list identity is preserved through verify and delete', () async {
    const identity = VerifiedStagedFileIdentity(
      basename: 'mobilka-1.2.3-windows-x64-aa.msi.part',
      size: 12,
      sha256: 'abc',
      identityToken: '7:8:9',
    );
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'safeList') {
        return [
          {..._map(identity), 'modifiedMillis': 1},
        ];
      }
      expect(call.arguments, containsPair('identityToken', '7:8:9'));
      if (call.method == 'verifyUpdate') return _map(identity);
      return null;
    });
    final bridge = WindowsMsiUpdateBridge(
      isWindows: true,
      stagingChannel: channel,
    );
    final listed = (await bridge.safeListUpdates(r'C:\updates')).single;
    final verified = await bridge.verifyStaged(
      r'C:\updates',
      listed.basename,
      listed.size,
      listed.sha256,
      identityToken: listed.identityToken,
    );
    expect(_map(verified!), _map(identity));
    await bridge.safeDeleteUpdate(r'C:\updates', verified);
    expect(methods, ['safeList', 'verifyUpdate', 'verifyUpdate', 'delete']);
  });

  test(
    'finalize returns native identity without invoking PowerShell',
    () async {
      const identity = VerifiedStagedFileIdentity(
        basename: 'mobilka-1.2.3-windows-x64-aa.msi',
        size: 12,
        sha256: 'abc',
        identityToken: '7:8:10',
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'finalizeUpdate');
        return _map(identity);
      });
      var ranPowerShell = false;
      final bridge = WindowsMsiUpdateBridge(
        isWindows: true,
        stagingChannel: channel,
        runProcess: (executable, arguments) async {
          ranPowerShell = true;
          throw StateError('PowerShell must not finalize staged files');
        },
      );
      final imported = await bridge.importVerified(
        r'C:\updates',
        '${identity.basename}.part',
        identity.basename,
        identity.size,
        identity.sha256,
      );
      expect(_map(imported), _map(identity));
      expect(ranPowerShell, isFalse);
    },
  );

  test(
    'apply propagates identity to verification and detached handoff',
    () async {
      final processArguments = <List<String>>[];
      List<String>? detachedArguments;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getTrustedSystemPaths');
        return {
          'powershell':
              r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        };
      });
      final bridge = WindowsMsiUpdateBridge(
        isWindows: true,
        executablePath: r'C:\Program Files\mobilka\mobilka.exe',
        processId: 42,
        stagingChannel: channel,
        runProcess: (executable, arguments) async {
          processArguments.add(arguments);
          if (arguments.contains('Provenance')) {
            return ProcessResult(
              1,
              0,
              '{"InstallType":"MSI","InstallLocation":"C:\\\\Program Files\\\\mobilka",'
                  '"UpgradeCode":"FDE6F32F-2EFE-5295-A1FA-534DFD36A8A9"}',
              '',
            );
          }
          return ProcessResult(2, 0, '{"Status":"Valid"}', '');
        },
        launchDetached: (executable, arguments) async {
          detachedArguments = arguments;
        },
      );

      await bridge.apply(
        'mobilka.msi',
        updatesRoot: r'C:\updates',
        expectedSize: 12,
        expectedSha256: 'a' * 64,
        identityToken: '7:8:9',
      );

      final verify = processArguments.singleWhere(
        (args) => args.contains('Verify'),
      );
      expect(verify, containsAllInOrder(['-IdentityToken', '7:8:9']));
      expect(
        detachedArguments,
        containsAllInOrder(['-IdentityToken', '7:8:9']),
      );
    },
  );
}

Map<String, Object?> _map(VerifiedStagedFileIdentity identity) => {
  'basename': identity.basename,
  'size': identity.size,
  'sha256': identity.sha256,
  'identityToken': identity.identityToken,
};
