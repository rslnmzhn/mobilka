import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/updater/data/github_update_repository.dart';
import 'package:mobilka/features/updater/data/update_http_client.dart';
import 'package:mobilka/features/updater/data/update_platform_bridge.dart';
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
      );

      final staged = await repository.download(_release(bytes));

      expect(await File(staged.path).readAsBytes(), bytes);
      expect(
        staged.path,
        matches(RegExp(r'mobilka-1\.2\.3-windows-x86_64-[0-9a-f]+\.msi$')),
      );
      expect(root.listSync().whereType<File>(), hasLength(1));
    },
  );

  test('download deletes partial data when size is wrong', () async {
    final repository = GithubUpdateRepository(
      http: _Http([1, 2, 3]),
      platform: platform,
    );

    await expectLater(
      repository.download(_release([1, 2, 3, 4])),
      throwsA(isA<UpdateException>()),
    );
    expect(root.listSync(), isEmpty);
  });

  test('Windows apply is allowed only for an MSI installation', () async {
    final repository = GithubUpdateRepository(
      http: _Http(const []),
      platform: platform,
    );
    final staged = StagedUpdate(release: _release([1]), path: 'update.msi');

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
  Future<void> installWindowsMsi(String path) async {
    windowsInstallCalls++;
  }

  @override
  Future<bool> installAndroidApk(String path, UpdateAsset asset) async => true;
}
