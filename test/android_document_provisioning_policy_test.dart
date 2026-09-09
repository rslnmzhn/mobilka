import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final script = File(
    'android/app/scripts/provision-android.ps1',
  ).readAsStringSync();

  test('provisioning roots are fixed and cannot be supplied by callers', () {
    expect(script, isNot(contains(r'[string]$OutputRoot')));
    expect(script, isNot(contains(r'[string]$AssetRoot')));
    expect(
      script,
      contains(r"$outputRoot = Join-Path $appRoot '.cxx/provision'"),
    );
    expect(
      script,
      contains(
        r"$assetRoot = Join-Path $workspaceRoot 'build/app/generated/document-assets/documents'",
      ),
    );
    expect(script, contains('ReparsePoint'));
    expect(script, contains('Assert-NoReparseAncestors'));
  });

  test('downloads use strict HTTPS redirect and digest policy', () {
    expect(script, contains("'--max-redirs' '3'"));
    expect(script, contains("'--proto' '=https'"));
    expect(script, contains("'--proto-redir' '=https'"));
    expect(script, contains('Get-FileHash -Algorithm SHA256'));
    expect(script, isNot(contains('Authorization')));
  });

  test('archives are listed and unsafe entry types and paths are rejected', () {
    expect(script, contains('tar -tzf'));
    expect(script, contains('tar -tvzf'));
    expect(script, contains("\$type -ne '-' -and \$type -ne 'd'"));
    expect(script, contains(r"$name.Contains('\')"));
    expect(script, contains(r"$name.Split('/') -contains '..'"));
  });

  test('dependency recipe receives its exact Android variable contract', () {
    expect(script, contains('-DDOCUMENTS_NDK='));
    expect(script, contains('-DDOCUMENTS_ABI='));
    expect(script, isNot(contains('-DDOCUMENTS_ANDROID_NDK=')));
    expect(script, isNot(contains('-DDOCUMENTS_ANDROID_ABI=')));
  });

  test('complete deterministic notice is provisioned as a generated asset', () {
    for (final dependency in [
      'ZLIB',
      'PNG',
      'JPEG',
      'LEPTONICA',
      'TESSERACT',
      'TESSDATA_FAST',
      'PDFIUM',
    ]) {
      expect(script, contains(r'$dependency LICENSE'));
    }
    expect(script, contains('Complete license file is absent for'));
    expect(script, contains("Join-Path \$assetRoot 'NOTICE.txt'"));
    expect(
      script,
      contains('PDFIUM license differs between provisioned Android ABIs'),
    );
  });

  test('packages complete dependency license notices', () {
    expect(script, contains('Complete license file is absent for'));
    expect(script, contains('===== PDFIUM LICENSE ====='));
    expect(script, contains("Join-Path \$assetRoot 'NOTICE.txt'"));
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(
      gradle,
      contains('"eng.traineddata", "rus.traineddata", "NOTICE.txt"'),
    );
  });

  test('verified outputs produce the CMake provision consumed by Gradle', () {
    expect(script, contains("'provision.cmake'"));
    expect(script, contains(r'DOCUMENTS_${name}_LIBRARY_SHA256'));
    expect(script, contains('PROVISIONING_MANIFEST ='));
    expect(script, contains('LICENSES ='));
    expect(script, contains(r'DOCUMENTS_$($entry.Key)_SHA256'));
  });

  test(
    'Tesseract configure disables TIFF try-run and LibArchive discovery',
    () {
      final recipe = File(
        'native/documents/build-dependencies.cmake',
      ).readAsStringSync();
      expect(recipe, contains('-DDISABLE_TIFF=ON'));
      expect(recipe, contains('-DLEPT_TIFF_RESULT=1'));
      expect(recipe, contains('-DLEPT_TIFF_COMPILE_SUCCESS=TRUE'));
      expect(recipe, contains('-DCMAKE_DISABLE_FIND_PACKAGE_LibArchive=ON'));
      expect(recipe, isNot(contains('-DBUILD_TESSERACT=OFF')));
      expect(recipe, contains('--target libtesseract'));
    },
  );

  test('Android Tesseract uses the checked-in conservative CPU feature shim', () {
    final recipe = File(
      'native/documents/build-dependencies.cmake',
    ).readAsStringSync();
    final dependencies = File(
      'native/documents/dependencies.cmake',
    ).readAsStringSync();
    final header = File(
      'native/documents/android_cpu_features/include/ndk_compat/cpu-features.h',
    ).readAsStringSync();
    final implementation = File(
      'native/documents/android_cpu_features/cpu-features.cpp',
    ).readAsStringSync();
    final package = File(
      'native/documents/android_cpu_features/CMakeLists.txt',
    ).readAsStringSync();
    final packageConfig = File(
      'native/documents/android_cpu_features/CpuFeaturesNdkCompatConfig.cmake',
    ).readAsStringSync();

    expect(recipe, contains('-DCpuFeaturesNdkCompat_DIR='));
    expect(recipe, contains('--target install'));
    expect(dependencies, contains('CpuFeatures::ndk_compat'));
    expect(package, contains('EXPORT_NAME ndk_compat'));
    expect(package, contains('NAMESPACE CpuFeatures::'));
    expect(packageConfig, contains('CpuFeaturesNdkCompatTargets.cmake'));
    expect(header, contains('android_getCpuFamily'));
    expect(header, contains('ANDROID_CPU_ARM_FEATURE_NEON'));
    expect(implementation, contains('uint64_t android_getCpuFeatures(void)'));
    expect(implementation, contains('return 0;'));
  });

  test(
    'dependency builds resume only from verified per-dependency markers',
    () {
      final recipe = File(
        'native/documents/build-dependencies.cmake',
      ).readAsStringSync();
      expect(recipe, contains(r'${DOCUMENTS_BUILD_ROOT}/${dep}.complete'));
      expect(
        recipe,
        contains(r'file(SHA256 "${CMAKE_CURRENT_LIST_FILE}" recipe_sha256)'),
      );
      expect(recipe, contains('source.properties'));
      expect(recipe, contains('dependency_lock_sha256'));
      expect(recipe, contains('actual_output_sha'));
      expect(recipe, contains('actual_header_sha'));
      expect(recipe, contains('already complete'));
      expect(recipe, contains(r'--parallel "${DOCUMENTS_PARALLEL}"'));
    },
  );

  test('provisioner supplies bounded host parallelism and ABI progress', () {
    expect(script, contains('[Math]::Min(4, [Environment]::ProcessorCount)'));
    expect(script, contains(r'-DDOCUMENTS_PARALLEL=$parallel'));
    expect(script, contains(r'provisioning $abi'));
  });

  test('CI caches verified provisions with manifest recipe and NDK identity', () {
    final workflow = File('.github/workflows/build.yml').readAsStringSync();
    expect(
      workflow,
      contains('actions/cache@5a3ec84eff668545956fd18022155c47e93e2684'),
    );
    expect(workflow, contains(r'ndk-${{ env.ANDROID_NDK_VERSION }}'));
    expect(
      workflow,
      contains(
        "hashFiles('native/documents/dependency-versions.json', 'native/documents/build-dependencies.cmake', 'android/app/scripts/provision-android.ps1')",
      ),
    );
    expect(workflow, contains('timeout-minutes: 60'));
  });
}
