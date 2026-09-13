import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String extract(String path, String pattern) {
  final matches = RegExp(pattern).allMatches(File(path).readAsStringSync());
  expect(matches, hasLength(1), reason: path);
  return matches.single.group(1)!;
}

void main() {
  // Execute the actual production patterns in Dart's regex engine. This is
  // contract coverage, not a substitute for native installer/device tests.
  final patterns = <String, String Function()>{
    'Android': () =>
        jsonDecode(
              extract(
                'android/app/src/main/kotlin/com/rslnmzhn/mobilka/MainActivity.kt',
                r'private fun isGeneratedName\(name: String\): Boolean = Regex\(\s*'
                    r'("(?:\\.|[^"\\])*")\s*,?\s*\)\.matches\(name\)',
              ),
            )
            as String,
    'Windows': () => extract(
      'windows/runner/updater_staging.cpp',
      r'const std::wregex kGenerated\(LR"\(([^\r\n]+)\)"\);',
    ),
    'PowerShell': () => extract(
      '.github/windows/mobilka_update.ps1',
      r'function Test-GeneratedName\(\[string\]\$Name\)\s*\{\s*'
          r"return \$Name -match '([^'\r\n]+)'\s*\}",
    ),
  };
  for (final entry in patterns.entries) {
    test('${entry.key} accepts stable and fix release staging names', () {
      final guard = RegExp(
        entry.value(),
        caseSensitive: entry.key != 'PowerShell',
      );
      for (final version in [
        '0.5.1',
        '0.5.1_fix1',
        '0.5.1_fix2',
        '0.5.1_fix10',
      ]) {
        for (final target in [
          'android-arm64-v8a-a09f.apk',
          'windows-x64-a09f.msi',
        ]) {
          for (final suffix in ['', '.part']) {
            final name = 'mobilka-$version-$target$suffix';
            expect(guard.hasMatch(name), isTrue, reason: name);
          }
        }
      }
    });
    test('${entry.key} rejects malformed fix suffixes and unsafe paths', () {
      final guard = RegExp(
        entry.value(),
        caseSensitive: entry.key != 'PowerShell',
      );
      final invalid = <String>[
        for (final fix in [
          '_fix',
          '_fix0',
          '_fix01',
          '_fix-1',
          '_fix1x',
          '_fix1_fix2',
        ])
          'mobilka-0.5.1$fix-android-arm64-v8a-a09f.apk',
        '../mobilka-0.5.1_fix2-android-arm64-v8a-a09f.apk',
        r'..\mobilka-0.5.1_fix2-windows-x64-a09f.msi',
        '/mobilka-0.5.1_fix2-android-arm64-v8a-a09f.apk',
        'mobilka-0.5.1_fix2-android-../arm64-a09f.apk',
        'other-0.5.1_fix2-android-arm64-v8a-a09f.apk',
        'mobilka-0.5.1_fix2-linux-x64-a09f.msi',
        'mobilka-0.5.1_fix2-windows-x64-a09f.msi.exe',
        'mobilka-0.5.1_fix2-windows-x64-a09f.msi.part.part',
        'mobilka-0.5.1_fix2-windows-x64-a09f.msi:stream',
        'mobilka-0.5.1_fix2-windows-x64-a09f.msi ',
        '',
      ];
      for (final name in invalid) {
        expect(guard.hasMatch(name), isFalse, reason: name);
      }
    });
  }
}
