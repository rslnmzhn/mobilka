import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final provision = File(
    '.github/scripts/provision_windows_document_worker.ps1',
  ).readAsStringSync();
  final broker = File(
    'windows/runner/document_worker_broker.cpp',
  ).readAsStringSync();
  final cmake = File('windows/CMakeLists.txt').readAsStringSync();
  final workerCmake = File(
    'windows/document_worker/CMakeLists.txt',
  ).readAsStringSync();
  final generator = File(
    '.github/scripts/generate_document_worker_manifest.ps1',
  ).readAsStringSync();

  test('Windows archives are prevalidated and extracted into a fresh tree', () {
    expect(provision, contains('tar -tzf'));
    expect(provision, contains('tar -tvzf'));
    expect(provision, contains(r"$name.Contains('\')"));
    expect(provision, contains(r"$segments -contains ''"));
    expect(provision, contains(r"$segments -contains '.'"));
    expect(provision, contains(r"$segments -contains '..'"));
    expect(provision, contains('OrdinalIgnoreCase'));
    expect(provision, contains('Archive contains a link or special entry'));
    expect(provision, contains('Remove-OwnedDirectory'));
    expect(provision, contains('Assert-NoReparseAncestors'));
    expect(provision, contains('Assert-OrdinaryTree'));
    expect(provision, contains('pinned digest changed before extraction'));
  });

  test('signed runner uses a generated embedded worker manifest', () {
    expect(cmake, contains('document_worker_manifest_header'));
    expect(cmake, contains('generate_document_worker_manifest.ps1'));
    expect(broker, contains('#include "document_worker_manifest_digest.h"'));
    expect(broker, contains('kDocumentWorkerManifest'));
    expect(broker, isNot(contains('std::ifstream stream(manifest)')));
    expect(broker, contains('FILE_FLAG_OPEN_REPARSE_POINT'));
    expect(broker, contains('SameIdentity(helper_identity, current_identity)'));
    expect(broker, contains('TrustedBundleProvenance'));
    expect(broker, contains('TokenElevation'));
    expect(cmake, isNot(contains('document_worker.sha256')));
    expect(workerCmake, isNot(contains('document_worker.sha256')));
    expect(generator, contains('Manifest input is a reparse point'));
    expect(generator, contains(r'[IO.Path]::GetDirectoryName($path)'));
    expect(generator, isNot(contains(r'$path.StartsWith($runtimePath')));
    for (final file in [
      'document_worker.exe',
      'pdfium.dll',
      'eng.traineddata',
      'rus.traineddata',
      'document-worker-notices.txt',
    ]) {
      expect(generator, contains("'$file'"));
    }
  });

  test('Windows notices concatenate complete source licenses', () {
    for (final dependency in [
      'ZLIB',
      'PNG',
      'JPEG',
      'LEPTONICA',
      'TESSERACT',
      'TESSDATA_FAST',
    ]) {
      expect(provision, contains('$dependency = Join-Path'));
    }
    expect(provision, contains(r'===== $dependency LICENSE ====='));
    expect(provision, contains(r'===== PDFIUM/$($_.Name) ====='));
    expect(provision, contains("-contains 'pdfium.txt'"));
    expect(provision, contains('Complete license file is absent for'));
  });
}
