import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/updater/data/github_update_repository.dart';
import 'package:mobilka/features/updater/data/update_http_client.dart';
import 'package:mobilka/features/updater/data/update_platform_bridge.dart';
import 'package:mobilka/features/updater/data/android_updater_bridge.dart';
import 'package:mobilka/features/updater/domain/update_release.dart';

void main() {
  late Directory root;
  late _Platform platform;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mobilka-updater-');
    platform = _Platform(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'download verifies exact size and SHA-256 before atomic staging',
    () async {
      final bytes = [1, 2, 3, 4];
      final repository = GithubUpdateRepository(
        http: _Http(bytes),
        platform: platform,
        signatureVerifier: _Verifier(),
      );

      await repository.download(_release(bytes));

      final stagedFile = root.listSync().whereType<File>().single;
      expect(await stagedFile.readAsBytes(), bytes);
      expect(
        stagedFile.path,
        matches(RegExp(r'mobilka-1\.2\.3-windows-x86_64-[0-9a-f]+\.msi$')),
      );
      expect(root.listSync().whereType<File>(), hasLength(1));
    },
  );

  test('download deletes partial data when size is wrong', () async {
    final repository = GithubUpdateRepository(
      http: _Http([1, 2, 3]),
      platform: platform,
      signatureVerifier: _Verifier(),
    );

    await expectLater(
      repository.download(_release([1, 2, 3, 4])),
      throwsA(isA<UpdateException>()),
    );
    expect(root.listSync(), isEmpty);
  });

  test('Windows apply is allowed only for an MSI installation', () async {
    final repository = GithubUpdateRepository(
      http: _Http(const [1]),
      platform: platform,
      signatureVerifier: _Verifier(),
    );
    final staged = await repository.download(_release([1]));

    expect(await repository.apply(staged), isFalse);
    expect(platform.windowsInstallCalls, 0);

    platform.msiInstalled = true;
    expect(await repository.apply(staged), isTrue);
    expect(platform.windowsInstallCalls, 1);
  });

  test(
    'latest verifies the exact manifest bytes and detached signature',
    () async {
      final manifest = utf8.encode('''{
  "schemaVersion": 1,
  "release": {"channel":"stable","tag":"v1.2.3","version":"1.2.3","draft":false,"prerelease":false},
  "assets": [{"platform":"windows","arch":"x86_64","format":"msi","primary":true,"installer":true,"applyMode":"msi","install":true,"fileName":"mobilka-v1.2.3-windows-x64.msi","size":4,"sha256":"${'0' * 64}","downloadUrl":"https://github.com/rslnmzhn/mobilka/releases/download/v1.2.3/mobilka-v1.2.3-windows-x64.msi"}]
}''');
      final signature = List<int>.generate(64, (index) => index);
      final manifestUrl =
          'https://github.com/rslnmzhn/mobilka/releases/download/v1.2.3/mobilka-v1.2.3-release-manifest.json';
      final signatureUrl = manifestUrl.replaceFirst('.json', '.sig');
      final metadata = utf8.encode(
        jsonEncode({
          'tag_name': 'v1.2.3',
          'draft': false,
          'prerelease': false,
          'assets': [
            {
              'name': 'mobilka-v1.2.3-release-manifest.json',
              'browser_download_url': manifestUrl,
            },
            {
              'name': 'mobilka-v1.2.3-release-manifest.sig',
              'browser_download_url': signatureUrl,
            },
          ],
        }),
      );
      final verifier = _Verifier();
      final repository = GithubUpdateRepository(
        http: _MappedHttp({
          GithubUpdateRepository.latestReleaseUri.toString(): metadata,
          manifestUrl: manifest,
          signatureUrl: signature,
        }),
        platform: platform,
        signatureVerifier: verifier,
      );

      final release = await repository.latest();

      expect(release.version, '1.2.3');
      expect(verifier.message, manifest);
      expect(verifier.signature, signature);
    },
  );
}

UpdateRelease _release(List<int> bytes) => UpdateRelease(
  version: '1.2.3',
  tag: 'v1.2.3',
  asset: UpdateAsset(
    platform: 'windows',
    architecture: 'x86_64',
    format: 'msi',
    fileName: 'untrusted-name.msi',
    size: bytes.length,
    sha256: sha256.convert(bytes).toString(),
    downloadUri: Uri.parse(
      'https://github.com/rslnmzhn/mobilka/releases/download/v1.2.3/update.msi',
    ),
    primary: true,
    applyMode: 'msi',
    install: true,
    installer: true,
  ),
  proof: StagedUpdateProof(
    manifestBytes: utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'release': {
          'channel': 'stable',
          'tag': 'v1.2.3',
          'version': '1.2.3',
          'draft': false,
          'prerelease': false,
        },
        'assets': [
          {
            'platform': 'windows',
            'arch': 'x86_64',
            'format': 'msi',
            'primary': true,
            'installer': true,
            'applyMode': 'msi',
            'install': true,
            'fileName': 'untrusted-name.msi',
            'size': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
            'downloadUrl':
                'https://github.com/rslnmzhn/mobilka/releases/download/v1.2.3/update.msi',
          },
        ],
      }),
    ),
    signatureBytes: List<int>.filled(64, 1),
  ),
);

class _Http implements UpdateHttpClient {
  _Http(this.bytes);

  final List<int> bytes;

  @override
  Future<UpdateHttpResponse> get(Uri uri) async => UpdateHttpResponse(
    uri: uri,
    contentLength: bytes.length,
    stream: Stream.value(bytes),
  );
}

class _MappedHttp implements UpdateHttpClient {
  _MappedHttp(this.responses);

  final Map<String, List<int>> responses;

  @override
  Future<UpdateHttpResponse> get(Uri uri) async {
    final bytes = responses[uri.toString()];
    if (bytes == null) throw StateError('Unexpected URI: $uri');
    return UpdateHttpResponse(
      uri: uri,
      contentLength: bytes.length,
      stream: Stream.value(bytes),
    );
  }
}

class _Verifier implements ManifestSignatureVerifier {
  List<int>? message;
  List<int>? signature;

  @override
  Future<bool> verify(List<int> message, List<int> signature) async {
    this.message = List.of(message);
    this.signature = List.of(signature);
    return true;
  }
}

class _Platform implements UpdatePlatformBridge {
  _Platform(this.directory);

  final Directory directory;
  bool msiInstalled = false;
  int windowsInstallCalls = 0;

  @override
  Future<UpdateTarget> target() async => const UpdateTarget(
    platform: UpdatePlatform.windows,
    architecture: 'x86_64',
  );

  @override
  Future<Directory> stagingDirectory() async => directory;

  @override
  Future<bool> isWindowsMsiInstalled() async => msiInstalled;

  @override
  Future<void> installWindowsMsi(
    String path,
    int expectedSize,
    String expectedSha256, {
    required String identityToken,
  }) async {
    windowsInstallCalls++;
  }

  @override
  Future<bool> installAndroidApk(
    String path,
    UpdateAsset asset, {
    String? identityToken,
  }) async => true;

  @override
  Future<List<SafeStagedFile>> safeListStaged() async => directory
      .listSync(followLinks: false)
      .whereType<File>()
      .map(
        (file) => SafeStagedFile(
          basename: file.uri.pathSegments.last,
          size: file.lengthSync(),
          modifiedMillis: file.lastModifiedSync().millisecondsSinceEpoch,
          sha256: sha256.convert(file.readAsBytesSync()).toString(),
          identityToken:
              '${file.lengthSync()}|${file.lastModifiedSync().millisecondsSinceEpoch}',
        ),
      )
      .toList();

  @override
  Future<void> safeDeleteStaged(
    String basename,
    int expectedSize,
    String expectedSha256, {
    String? identityToken,
  }) => File('${directory.path}${Platform.pathSeparator}$basename').delete();

  @override
  Future<SafeDownloadSink> beginDownload(String partialName) async {
    final file = File('${directory.path}${Platform.pathSeparator}$partialName');
    await file.create(exclusive: true);
    return _TestSink(file);
  }

  @override
  Future<VerifiedStagedFileIdentity> importVerifiedDownload(
    String partialName,
    String finalName,
    int expectedSize,
    String expectedSha256,
  ) async {
    final destination = File(
      '${directory.path}${Platform.pathSeparator}$finalName',
    );
    await File(
      '${directory.path}${Platform.pathSeparator}$partialName',
    ).rename(destination.path);
    return (await verifyStaged(finalName, expectedSize, expectedSha256))!;
  }

  @override
  Future<VerifiedStagedFileIdentity?> verifyStaged(
    String basename,
    int expectedSize,
    String expectedSha256, {
    String? identityToken,
  }) async {
    final file = File('${directory.path}${Platform.pathSeparator}$basename');
    if (!file.existsSync()) return null;
    final hash = sha256.convert(await file.readAsBytes()).toString();
    final identity =
        '${file.lengthSync()}|${file.lastModifiedSync().millisecondsSinceEpoch}';
    if (file.lengthSync() != expectedSize ||
        hash != expectedSha256 ||
        (identityToken != null && identity != identityToken)) {
      return null;
    }
    return VerifiedStagedFileIdentity(
      basename: basename,
      size: expectedSize,
      sha256: hash,
      identityToken: identity,
    );
  }

  @override
  Future<int?> installedVersionCode() async => null;

  @override
  Future<void> rotateWindowsHandoffLog() async {}
}

class _TestSink implements SafeDownloadSink {
  _TestSink(this.file);
  final File file;
  @override
  Future<void> write(List<int> chunk) =>
      file.writeAsBytes(chunk, mode: FileMode.append);
  @override
  Future<void> finish() async {}
  @override
  Future<void> abort() async {
    if (await file.exists()) await file.delete();
  }
}
