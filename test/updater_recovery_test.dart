import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/updater/application/update_controller.dart';
import 'package:mobilka/features/updater/data/android_updater_bridge.dart';
import 'package:mobilka/features/updater/data/github_update_repository.dart';
import 'package:mobilka/features/updater/data/update_http_client.dart';
import 'package:mobilka/features/updater/data/update_platform_bridge.dart';
import 'package:mobilka/features/updater/domain/staged_update_metadata.dart';
import 'package:mobilka/features/updater/domain/update_release.dart';

void main() {
  late Directory root;
  late _SafePlatform platform;
  late MemoryStagedUpdateStore store;
  final now = DateTime.utc(2026, 8, 30, 12);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mobilka-recovery-');
    platform = _SafePlatform(root);
    store = MemoryStagedUpdateStore();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  GithubUpdateRepository repository({UpdateHttpClient? http}) =>
      GithubUpdateRepository(
        http: http ?? _BytesHttp(const [1, 2, 3]),
        platform: platform,
        stagedStore: store,
        clock: () => now,
        signatureVerifier: _AllowVerifier(),
      );

  test('safe bridge rejects outside, nested and symlink children', () async {
    final outside = await File(
      '${root.parent.path}/outside.msi',
    ).writeAsBytes([1]);
    final nested = Directory('${root.path}/nested')..createSync();
    await File(
      '${nested.path}/mobilka-1.0.0-windows-x64-aa.msi',
    ).writeAsBytes([1]);
    final link = Link('${root.path}/mobilka-1.0.0-windows-x64-bb.msi');
    var linksSupported = true;
    try {
      await link.create(outside.path);
    } on FileSystemException {
      linksSupported = false;
    }

    expect(await platform.safeListStaged(), isEmpty);
    await expectLater(
      platform.safeDeleteStaged('../outside.msi', 1, 'x'),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      platform.safeDeleteStaged(
        'nested/mobilka-1.0.0-windows-x64-aa.msi',
        1,
        'x',
      ),
      throwsA(isA<StateError>()),
    );
    if (linksSupported) {
      await expectLater(
        platform.safeDeleteStaged(link.uri.pathSegments.last, 1, 'x'),
        throwsA(isA<StateError>()),
      );
    }
    expect(await outside.readAsBytes(), [1]);
    await outside.delete();
  });

  test('root link and replacement identity fail closed', () async {
    platform.rootSafe = false;
    await expectLater(platform.safeListStaged(), throwsStateError);
    platform.rootSafe = true;
    final file = await _put(root, 'mobilka-1.0.0-windows-x64-aa.msi', [1], now);
    platform.replaceBeforeDelete = true;
    await expectLater(
      platform.safeDeleteStaged(
        file.uri.pathSegments.last,
        1,
        sha256.convert([1]).toString(),
      ),
      throwsStateError,
    );
    expect(await file.exists(), isTrue);
  });

  test('cleanup enforces 24h, 7d, max one part and max two finals', () async {
    await _put(
      root,
      'mobilka-1.0.0-windows-x64-aa.msi.part',
      [1],
      now.subtract(const Duration(hours: 1)),
    );
    await _put(
      root,
      'mobilka-1.0.1-windows-x64-bb.msi.part',
      [1],
      now.subtract(const Duration(hours: 24)),
    );
    await _put(
      root,
      'mobilka-1.0.2-windows-x64-cc.msi',
      [1],
      now.subtract(const Duration(days: 8)),
    );
    await _put(
      root,
      'mobilka-1.0.3-windows-x64-dd.msi',
      [1],
      now.subtract(const Duration(hours: 1)),
    );
    await _put(
      root,
      'mobilka-1.0.4-windows-x64-ee.msi',
      [1],
      now.subtract(const Duration(hours: 2)),
    );
    await _put(
      root,
      'mobilka-1.0.5-windows-x64-ff.msi',
      [1],
      now.subtract(const Duration(hours: 3)),
    );

    await repository().recover('0.0.1');

    expect(platform.names, [
      'mobilka-1.0.0-windows-x64-aa.msi.part',
      'mobilka-1.0.3-windows-x64-dd.msi',
      'mobilka-1.0.4-windows-x64-ee.msi',
    ]);
    expect(
      platform.deleted,
      containsAll([
        'mobilka-1.0.1-windows-x64-bb.msi.part',
        'mobilka-1.0.2-windows-x64-cc.msi',
        'mobilka-1.0.5-windows-x64-ff.msi',
      ]),
    );
  });

  test(
    'protected verified final survives count and expires at 30 days',
    () async {
      final bytes = [7, 8];
      final protected = await _put(
        root,
        'mobilka-2.0.0-windows-x64-aa.msi',
        bytes,
        now.subtract(const Duration(days: 20)),
      );
      store.value = _metadata(protected, bytes, now, version: '2.0.0');
      await _put(root, 'mobilka-2.0.1-windows-x64-bb.msi', [1], now);
      await _put(
        root,
        'mobilka-2.0.2-windows-x64-cc.msi',
        [1],
        now.subtract(const Duration(hours: 1)),
      );
      expect(await repository().recover('1.0.0'), isNotNull);
      expect(platform.names, contains(protected.uri.pathSegments.last));

      await protected.setLastModified(now.subtract(const Duration(days: 30)));
      expect(await repository().recover('1.0.0'), isNull);
      expect(platform.names, isNot(contains(protected.uri.pathSegments.last)));
    },
  );

  test(
    'downloading crash leaves metadata and part, startup bounds it',
    () async {
      final part = await _put(
        root,
        'mobilka-2.0.0-windows-x64-aa.msi.part',
        [1],
        now.subtract(const Duration(hours: 25)),
      );
      store.value = _metadata(
        File(part.path.substring(0, part.path.length - 5)),
        [1],
        now,
        lifecycle: StagedUpdateLifecycle.downloading,
        version: '2.0.0',
      );
      expect(await repository().recover('1.0.0'), isNull);
      expect(await part.exists(), isFalse);
      expect(store.value, isNull);
    },
  );

  test('old installed version preserves exact reverified file', () async {
    final bytes = [4, 5, 6];
    final file = await _put(
      root,
      'mobilka-2.0.0-windows-x64-aa.msi',
      bytes,
      now,
    );
    store.value = _metadata(file, bytes, now, version: '2.0.0');
    final recovered = await repository().recover('1.9.9');
    expect(recovered?.id, contains(file.uri.pathSegments.last));
    expect(await file.exists(), isTrue);
  });

  test(
    'hash or size mismatch clears retry without deleting fresh final',
    () async {
      final file = await _put(root, 'mobilka-2.0.0-windows-x64-aa.msi', [
        9,
      ], now);
      store.value = _metadata(file, [1, 2], now, version: '2.0.0');
      expect(await repository().recover('1.0.0'), isNull);
      expect(store.value, isNull);
      expect(await file.exists(), isTrue);
    },
  );

  test('Android installed target deletes exact files and clears', () async {
    platform.targetValue = const UpdateTarget(
      platform: UpdatePlatform.android,
      architecture: 'arm64-v8a',
    );
    platform.versionCode = 2002000;
    final bytes = [1];
    final file = await _put(
      root,
      'mobilka-2.0.0-android-arm64-v8a-aa.apk',
      bytes,
      now,
    );
    final part = await _put(
      root,
      '${file.uri.pathSegments.last}.part',
      bytes,
      now,
    );
    store.value = _metadata(
      file,
      bytes,
      now,
      platform: 'android',
      versionCode: 2002000,
      version: '2.0.0',
    );
    expect(await repository().recover('0.0.1'), isNull);
    expect(await file.exists(), isFalse);
    expect(await part.exists(), isFalse);
    expect(store.value, isNull);
  });

  for (final launched in [false, true]) {
    test(
      'Android ${launched ? 'launched' : 'permission/cancel'} preserves verified package',
      () async {
        platform.targetValue = const UpdateTarget(
          platform: UpdatePlatform.android,
          architecture: 'arm64-v8a',
        );
        platform.androidLaunched = launched;
        final staged = await repository(http: _BytesHttp(const [1, 2, 3]))
            .download(
              _release(
                const [1, 2, 3],
                platform: 'android',
                format: 'apk',
                versionCode: 1004003,
              ),
            );
        expect(await repository().apply(staged), launched);
        expect(platform.names, contains(store.value!.fileName));
        expect(
          store.value!.lifecycle,
          launched
              ? StagedUpdateLifecycle.installerLaunched
              : StagedUpdateLifecycle.permissionRequired,
        );
      },
    );
  }

  test(
    'Windows semantic current target deletes and rotates; old preserves',
    () async {
      final bytes = [3];
      final file = await _put(
        root,
        'mobilka-2.10.0-windows-x64-aa.msi',
        bytes,
        now,
      );
      store.value = _metadata(file, bytes, now, version: '2.10.0');
      expect(await repository().recover('2.9.9'), isNotNull);
      expect(platform.rotations, 0);
      expect(await repository().recover('2.10.0'), isNull);
      expect(platform.rotations, 1);
      expect(await file.exists(), isFalse);
    },
  );

  test(
    'predownload preserves and reuses protected matching verified package',
    () async {
      final bytes = [1, 2, 3];
      final file = await _put(
        root,
        'mobilka-1.2.3-windows-x64-aa.msi',
        bytes,
        now.subtract(const Duration(days: 20)),
      );
      store.value = _metadata(file, bytes, now, version: '1.2.3');
      final http = _BytesHttp(bytes);
      final staged = await repository(http: http).download(_release(bytes));
      expect(staged.id, contains(file.uri.pathSegments.last));
      expect(http.calls, 1);
    },
  );

  test(
    'metadata is persisted before exclusive part create and collision is not truncated',
    () async {
      final http = _BytesHttp([1, 2, 3]);
      platform.createCollision = true;
      platform.readMetadata = () => store.value;
      await expectLater(
        repository(http: http).download(_release(const [1, 2, 3])),
        throwsA(anything),
      );
      expect(
        platform.metadataAtCollision?.lifecycle,
        StagedUpdateLifecycle.downloading,
      );
      expect(platform.collisionBytes, [99]);
    },
  );

  test('malformed metadata authorizes no metadata-target deletion', () async {
    final fresh = await _put(root, 'mobilka-9.9.9-windows-x64-aa.msi', [
      1,
    ], now);
    final malformed = _MalformedStore();
    final repo = GithubUpdateRepository(
      http: _BytesHttp(const []),
      platform: platform,
      stagedStore: malformed,
      clock: () => now,
      signatureVerifier: _AllowVerifier(),
    );
    expect(await repo.recover('9.9.9'), isNull);
    expect(await fresh.exists(), isTrue);
    expect(platform.deleted, isEmpty);
  });

  test(
    'controller recovers before check and check failure retains retry',
    () async {
      final staged = StagedUpdate(
        release: _release(const [1]),
        path: 'safe.msi',
      );
      final fake = _ControllerRepository(staged);
      final controller = UpdateController(
        repository: fake,
        currentVersion: Future.value('1.0.0'),
      );
      await controller.recoverThenCheck();
      await controller.check();
      expect(fake.events, ['recover', 'recover', 'latest']);
      expect(controller.state.status, UpdateStatus.failed);
      expect(controller.state.staged, same(staged));
    },
  );

  test('apply failure keeps staged projection for immediate retry', () async {
    final staged = StagedUpdate(release: _release(const [1]), path: 'safe.msi');
    final fake = _ControllerRepository(staged)..applyError = true;
    final controller = UpdateController(
      repository: fake,
      currentVersion: Future.value('1.0.0'),
    );
    await controller.recoverThenCheck();
    await controller.retryInstall();
    expect(controller.state.status, UpdateStatus.failed);
    expect(controller.state.staged, same(staged));
    fake.applyError = false;
    await controller.retryInstall();
    expect(fake.applyCalls, 2);
  });
}

Future<File> _put(
  Directory root,
  String name,
  List<int> bytes,
  DateTime modified,
) async {
  final file = await File(
    '${root.path}${Platform.pathSeparator}$name',
  ).writeAsBytes(bytes);
  await file.setLastModified(modified);
  return file;
}

StagedUpdateMetadata _metadata(
  File file,
  List<int> bytes,
  DateTime now, {
  String platform = 'windows',
  String version = '1.2.3',
  int? versionCode,
  StagedUpdateLifecycle lifecycle = StagedUpdateLifecycle.verified,
}) {
  final name = file.uri.pathSegments.last;
  return StagedUpdateMetadata(
    lifecycle: lifecycle,
    platform: platform,
    format: platform == 'android' ? 'apk' : 'msi',
    version: version,
    versionCode: versionCode,
    expectedSize: bytes.length,
    sha256: sha256.convert(bytes).toString(),
    fileName: name,
    partialName: '$name.part',
    createdAt: now.subtract(const Duration(days: 40)),
    updatedAt: now,
    attemptCount: 0,
    manifestBase64: base64.encode(
      utf8.encode(
        _manifestJson(
          bytes,
          platform: platform,
          version: version,
          versionCode: versionCode,
        ),
      ),
    ),
    signatureBase64: base64.encode(List<int>.filled(64, 1)),
  );
}

UpdateRelease _release(
  List<int> bytes, {
  String platform = 'windows',
  String format = 'msi',
  int? versionCode,
}) => UpdateRelease(
  version: '1.2.3',
  tag: 'v1.2.3',
  asset: UpdateAsset(
    platform: platform,
    architecture: platform == 'android' ? 'arm64-v8a' : 'x86_64',
    format: format,
    fileName: platform == 'android'
        ? 'mobilka-v1.2.3-android-arm64-v8a.apk'
        : 'mobilka-v1.2.3-windows-x64.msi',
    size: bytes.length,
    sha256: sha256.convert(bytes).toString(),
    downloadUri: Uri.https(
      'github.com',
      '/rslnmzhn/mobilka/releases/download/v1.2.3/${platform == 'android' ? 'mobilka-v1.2.3-android-arm64-v8a.apk' : 'mobilka-v1.2.3-windows-x64.msi'}',
    ),
    primary: true,
    applyMode: platform == 'android' ? 'packageInstaller' : 'msi',
    install: true,
    installer: platform == 'android' ? null : true,
    applicationId: platform == 'android' ? 'com.rslnmzhn.mobilka' : null,
    versionCode: versionCode,
  ),
  proof: StagedUpdateProof(
    manifestBytes: utf8.encode(
      _manifestJson(bytes, platform: platform, versionCode: versionCode),
    ),
    signatureBytes: List<int>.filled(64, 1),
  ),
);

String _manifestJson(
  List<int> bytes, {
  required String platform,
  String version = '1.2.3',
  int? versionCode,
}) {
  final android = platform == 'android';
  final name = android
      ? 'mobilka-v$version-android-arm64-v8a.apk'
      : 'mobilka-v$version-windows-x64.msi';
  return jsonEncode({
    'schemaVersion': 1,
    'release': {
      'channel': 'stable',
      'tag': 'v$version',
      'version': version,
      'draft': false,
      'prerelease': false,
    },
    'assets': [
      {
        'platform': platform,
        'arch': android ? 'arm64-v8a' : 'x86_64',
        'format': android ? 'apk' : 'msi',
        'primary': true,
        if (!android) 'installer': true,
        'applyMode': android ? 'packageInstaller' : 'msi',
        'install': true,
        'fileName': name,
        'size': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
        'downloadUrl':
            'https://github.com/rslnmzhn/mobilka/releases/download/v$version/$name',
        if (android) 'applicationId': 'com.rslnmzhn.mobilka',
        if (android) 'versionCode': versionCode,
      },
    ],
  });
}

class _AllowVerifier implements ManifestSignatureVerifier {
  @override
  Future<bool> verify(List<int> message, List<int> signature) async => true;
}

class _BytesHttp implements UpdateHttpClient {
  _BytesHttp(this.bytes);
  final List<int> bytes;
  int calls = 0;
  @override
  Future<UpdateHttpResponse> get(Uri uri) async {
    calls++;
    return UpdateHttpResponse(
      uri: uri,
      contentLength: bytes.length,
      stream: Stream.value(bytes),
    );
  }
}

class _MalformedStore implements StagedUpdateStore {
  @override
  Future<StagedUpdateMetadata?> load() async => null;
  @override
  Future<void> clear() async {}
  @override
  Future<void> save(StagedUpdateMetadata metadata) async {}
}

class _SafePlatform implements UpdatePlatformBridge {
  _SafePlatform(this.directory);
  final Directory directory;
  bool rootSafe = true;
  bool replaceBeforeDelete = false;
  bool createCollision = false;
  List<int>? collisionBytes;
  StagedUpdateMetadata? Function()? readMetadata;
  StagedUpdateMetadata? metadataAtCollision;
  bool androidLaunched = false;
  int? versionCode;
  int rotations = 0;
  final List<String> deleted = [];
  UpdateTarget targetValue = const UpdateTarget(
    platform: UpdatePlatform.windows,
    architecture: 'x86_64',
  );
  RegExp get grammar => RegExp(
    r'^mobilka-\d+\.\d+\.\d+-(android|windows)-[A-Za-z0-9_-]+-[0-9a-f]+\.(apk|msi)(\.part)?$',
  );
  List<String> get names =>
      directory
          .listSync(followLinks: false)
          .whereType<File>()
          .map((e) => e.uri.pathSegments.last)
          .toList()
        ..sort();
  void _root() {
    if (!rootSafe) {
      throw StateError('unsafe root');
    }
  }

  @override
  Future<Directory> stagingDirectory() async => directory;
  @override
  Future<UpdateTarget> target() async => targetValue;
  @override
  Future<int?> installedVersionCode() async => versionCode;
  @override
  Future<bool> isWindowsMsiInstalled() async => true;
  @override
  Future<bool> installAndroidApk(
    String path,
    UpdateAsset asset, {
    String? identityToken,
  }) async => androidLaunched;
  @override
  Future<void> installWindowsMsi(
    String path,
    int expectedSize,
    String expectedSha256, {
    required String identityToken,
  }) async {}
  @override
  Future<void> rotateWindowsHandoffLog() async {
    rotations++;
  }

  @override
  Future<List<SafeStagedFile>> safeListStaged() async {
    _root();
    if (createCollision) {
      final parts = directory
          .listSync(followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('.part'));
      if (parts.isNotEmpty) {
        createCollision = false;
        metadataAtCollision = readMetadata?.call();
        await parts.single.writeAsBytes([99]);
        collisionBytes = await parts.single.readAsBytes();
      }
    }
    return directory
        .listSync(followLinks: false)
        .whereType<File>()
        .where((file) => grammar.hasMatch(file.uri.pathSegments.last))
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
  }

  @override
  Future<void> safeDeleteStaged(
    String basename,
    int expectedSize,
    String expectedSha256, {
    String? identityToken,
  }) async {
    _root();
    if (!grammar.hasMatch(basename) ||
        basename.contains('/') ||
        basename.contains('\\')) {
      throw StateError('unsafe basename');
    }
    final file = File('${directory.path}${Platform.pathSeparator}$basename');
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('unsafe child');
    }
    final before = file.statSync();
    if (replaceBeforeDelete) {
      replaceBeforeDelete = false;
      return Future.error(StateError('identity changed'));
    }
    final after = file.statSync();
    if (before.size != after.size || before.modified != after.modified) {
      throw StateError('identity changed');
    }
    await file.delete();
    deleted.add(basename);
  }

  @override
  Future<SafeDownloadSink> beginDownload(String partialName) async {
    final file = File('${directory.path}${Platform.pathSeparator}$partialName');
    if (createCollision) {
      createCollision = false;
      metadataAtCollision = readMetadata?.call();
      await file.writeAsBytes([99]);
      collisionBytes = await file.readAsBytes();
    }
    await file.create(exclusive: true);
    return _FakeSink(file);
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
    if (createCollision) {
      metadataAtCollision = readMetadata?.call();
      createCollision = false;
      await destination.writeAsBytes([99]);
      collisionBytes = await destination.readAsBytes();
      throw StateError('collision');
    }
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
}

class _FakeSink implements SafeDownloadSink {
  _FakeSink(this.file);
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

class _ControllerRepository implements UpdateRepository {
  _ControllerRepository(this.staged);
  final StagedUpdate staged;
  final List<String> events = [];
  bool applyError = false;
  int applyCalls = 0;
  @override
  Future<StagedUpdate?> recover(String installedVersion) async {
    events.add('recover');
    return staged;
  }

  @override
  Future<UpdateRelease> latest() async {
    events.add('latest');
    throw StateError('offline');
  }

  @override
  Future<StagedUpdate> download(UpdateRelease release) =>
      throw UnimplementedError();
  @override
  Future<bool> apply(StagedUpdate update) async {
    applyCalls++;
    if (applyError) throw StateError('apply failed');
    return true;
  }
}
