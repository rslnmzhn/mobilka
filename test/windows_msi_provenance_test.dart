import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/updater/data/windows_msi_provenance.dart';

void main() {
  group('Windows MSI provenance parser', () {
    test('parses complete registry marker', () {
      final marker = WindowsMsiProvenance.parseRegistryOutput(
        '{"InstallType":"MSI","InstallLocation":"C:\\\\Program Files\\\\mobilka\\\\",'
        '"UpgradeCode":"FDE6F32F-2EFE-5295-A1FA-534DFD36A8A9"}',
      );

      expect(marker, isNotNull);
      expect(marker!.installType, 'MSI');
      expect(marker.installLocation, r'C:\Program Files\mobilka\');
    });

    test('rejects malformed and incomplete output', () {
      expect(WindowsMsiProvenance.parseRegistryOutput('not-json'), isNull);
      expect(
        WindowsMsiProvenance.parseRegistryOutput('{"InstallType":"MSI"}'),
        isNull,
      );
    });
  });

  group('Windows MSI auto-apply policy', () {
    const validMarker = WindowsMsiProvenance(
      installType: 'MSI',
      installLocation: r'C:\Program Files\mobilka\',
      upgradeCode: mobilkaMsiUpgradeCode,
    );

    test('allows executable under exact recorded install location', () {
      final result = evaluateWindowsMsiProvenance(
        marker: validMarker,
        executablePath: r'c:\PROGRAM FILES\mobilka\mobilka.exe',
      );

      expect(result.allowed, isTrue);
    });

    test('denies portable or unknown installs', () {
      final result = evaluateWindowsMsiProvenance(
        marker: null,
        executablePath: r'C:\Users\me\Downloads\mobilka.exe',
      );

      expect(result.allowed, isFalse);
      expect(result.denial, WindowsMsiProvenanceDenial.missingMarker);
    });

    test('denies wrong install type and UpgradeCode', () {
      final portable = evaluateWindowsMsiProvenance(
        marker: const WindowsMsiProvenance(
          installType: 'Portable',
          installLocation: r'C:\Program Files\mobilka',
          upgradeCode: mobilkaMsiUpgradeCode,
        ),
        executablePath: r'C:\Program Files\mobilka\mobilka.exe',
      );
      final foreignMsi = evaluateWindowsMsiProvenance(
        marker: const WindowsMsiProvenance(
          installType: 'MSI',
          installLocation: r'C:\Program Files\mobilka',
          upgradeCode: '00000000-0000-0000-0000-000000000000',
        ),
        executablePath: r'C:\Program Files\mobilka\mobilka.exe',
      );

      expect(portable.denial, WindowsMsiProvenanceDenial.wrongInstallType);
      expect(foreignMsi.denial, WindowsMsiProvenanceDenial.wrongUpgradeCode);
    });

    test('denies sibling prefixes and traversal in recorded location', () {
      final sibling = evaluateWindowsMsiProvenance(
        marker: validMarker,
        executablePath: r'C:\Program Files\mobilka-portable\mobilka.exe',
      );
      final traversal = evaluateWindowsMsiProvenance(
        marker: const WindowsMsiProvenance(
          installType: 'MSI',
          installLocation: r'C:\Program Files\other\..\mobilka',
          upgradeCode: mobilkaMsiUpgradeCode,
        ),
        executablePath: r'C:\Program Files\mobilka\mobilka.exe',
      );

      expect(
        sibling.denial,
        WindowsMsiProvenanceDenial.executableOutsideInstallLocation,
      );
      expect(
        traversal.denial,
        WindowsMsiProvenanceDenial.invalidInstallLocation,
      );
    });

    test('denies relative locations and executable equal to the directory', () {
      final relative = evaluateWindowsMsiProvenance(
        marker: const WindowsMsiProvenance(
          installType: 'MSI',
          installLocation: r'Program Files\mobilka',
          upgradeCode: mobilkaMsiUpgradeCode,
        ),
        executablePath: r'C:\Program Files\mobilka\mobilka.exe',
      );
      final directoryOnly = evaluateWindowsMsiProvenance(
        marker: validMarker,
        executablePath: r'C:\Program Files\mobilka',
      );

      expect(
        relative.denial,
        WindowsMsiProvenanceDenial.invalidInstallLocation,
      );
      expect(
        directoryOnly.denial,
        WindowsMsiProvenanceDenial.executableOutsideInstallLocation,
      );
    });
  });
}
