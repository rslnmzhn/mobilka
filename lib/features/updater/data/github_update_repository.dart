import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import '../domain/update_manifest.dart';
import '../domain/update_release.dart';
import 'update_http_client.dart';
import 'update_platform_bridge.dart';

class GithubUpdateRepository {
  GithubUpdateRepository({
    required UpdateHttpClient http,
    required UpdatePlatformBridge platform,
    ManifestSignatureVerifier? signatureVerifier,
  }) : _http = http,
       _platform = platform,
       _signatureVerifier =
           signatureVerifier ?? const Ed25519ManifestVerifier();

  static final latestReleaseUri = Uri.https(
    'api.github.com',
    '/repos/rslnmzhn/mobilka/releases/latest',
  );
  static const publicKeyBase64 = 'nH/Hnmn7UJtCy4Qb91c9dIAwQ3LSUkv6yRhDhMlZ3JY=';

  final UpdateHttpClient _http;
  final UpdatePlatformBridge _platform;
  final ManifestSignatureVerifier _signatureVerifier;

  Future<UpdateRelease> latest() async {
    final metadata = jsonDecode(
      utf8.decode(
        await _readBounded(
          await _http.get(latestReleaseUri),
          UpdateLimits.maxReleaseMetadataBytes,
        ),
      ),
    );
    if (metadata is! Map<String, dynamic> ||
        metadata['draft'] != false ||
        metadata['prerelease'] != false ||
        metadata['tag_name'] is! String ||
        metadata['assets'] is! List) {
      throw const UpdateException('GitHub returned invalid release metadata');
    }
    final assets = metadata['assets'] as List;
    final manifestAssets = assets.whereType<Map>().where(
      (asset) =>
          asset['name'] is String &&
          RegExp(
            r'^mobilka-v\d+\.\d+\.\d+-release-manifest\.json$',
          ).hasMatch(asset['name'] as String),
    );
    if (manifestAssets.length != 1) {
      throw const UpdateException('Release has no unique update manifest');
    }
    final manifestAsset = manifestAssets.single;
    final manifestName = manifestAsset['name'] as String;
    final signatureName =
        '${manifestName.substring(0, manifestName.length - '.json'.length)}.sig';
    final signatureAssets = assets.whereType<Map>().where(
      (asset) => asset['name'] == signatureName,
    );
    if (signatureAssets.length != 1) {
      throw const UpdateException('Release has no unique manifest signature');
    }
    final manifestUri = _assetUri(manifestAsset);
    final signatureUri = _assetUri(signatureAssets.single);
    final manifestBytes = await _readBounded(
      await _http.get(manifestUri),
      UpdateLimits.maxManifestBytes,
    );
    final signatureBytes = await _readBounded(
      await _http.get(signatureUri),
      UpdateLimits.maxSignatureBytes,
    );
    if (signatureBytes.length != 64) {
      throw const UpdateException('Manifest signature has an invalid length');
    }
    final valid = await _signatureVerifier.verify(
      manifestBytes,
      signatureBytes,
    );
    if (!valid) throw const UpdateException('Manifest signature is invalid');

    final manifest = UpdateManifest.parse(manifestBytes);
    if (metadata['tag_name'] != manifest.tag ||
        manifestName != 'mobilka-${manifest.tag}-release-manifest.json') {
      throw const UpdateException('Release metadata does not match manifest');
    }
    for (final asset in manifest.assets) {
      final expected = Uri.https(
        'github.com',
        '/rslnmzhn/mobilka/releases/download/${manifest.tag}/${asset.fileName}',
      );
      if (asset.downloadUri != expected) {
        throw const UpdateException(
          'Manifest contains an unexpected asset URL',
        );
      }
    }
    return manifest.select(await _platform.target());
  }

  Future<StagedUpdate> download(UpdateRelease release) async {
    final response = await _http.get(release.asset.downloadUri);
    if (response.contentLength != null &&
        response.contentLength != release.asset.size) {
      throw const UpdateException('Installer size does not match manifest');
    }
    final directory = await _platform.stagingDirectory();
    await directory.create(recursive: true);
    final nonce = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    final safeName =
        'mobilka-${release.version}-${release.asset.platform}-'
        '${release.asset.architecture}-$nonce.${release.asset.format}';
    final destination = File(
      '${directory.path}${Platform.pathSeparator}$safeName',
    );
    final temporary = File('${destination.path}.part');
    final digestSink = _DigestSink();
    final hashInput = hashes.sha256.startChunkedConversion(digestSink);
    var received = 0;
    IOSink? output;
    var hashClosed = false;
    try {
      output = temporary.openWrite(mode: FileMode.writeOnly);
      await for (final chunk in response.stream) {
        received += chunk.length;
        if (received > release.asset.size) {
          throw const UpdateException('Installer exceeds declared size');
        }
        hashInput.add(chunk);
        output.add(chunk);
      }
      await output.flush();
      await output.close();
      output = null;
      hashInput.close();
      hashClosed = true;
      if (received != release.asset.size ||
          digestSink.value.toString() != release.asset.sha256) {
        throw const UpdateException('Installer integrity check failed');
      }
      await temporary.rename(destination.path);
      return StagedUpdate(release: release, path: destination.path);
    } catch (_) {
      await output?.close();
      if (!hashClosed) hashInput.close();
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<bool> apply(StagedUpdate update) async {
    final target = await _platform.target();
    switch (target.platform) {
      case UpdatePlatform.android:
        return _platform.installAndroidApk(update.path, update.release.asset);
      case UpdatePlatform.windows:
        if (!await _platform.isWindowsMsiInstalled()) return false;
        await _platform.installWindowsMsi(update.path);
        return true;
      case UpdatePlatform.unsupported:
        throw const UpdateException(
          'Updates are not supported on this platform',
        );
    }
  }

  static Uri _assetUri(Map<dynamic, dynamic> asset) {
    final value = asset['browser_download_url'];
    final uri = value is String ? Uri.tryParse(value) : null;
    if (uri == null) {
      throw const UpdateException('Release asset URL is invalid');
    }
    return uri;
  }

  static List<int> _strictBase64(String value, int length, String label) {
    try {
      final decoded = base64.decode(value);
      if (decoded.length != length || base64.encode(decoded) != value) {
        throw const FormatException();
      }
      return decoded;
    } on FormatException {
      throw UpdateException('Invalid $label encoding');
    }
  }

  static Future<List<int>> _readBounded(
    UpdateHttpResponse response,
    int maximum,
  ) async {
    if (response.contentLength != null && response.contentLength! > maximum) {
      throw const UpdateException('Update response is too large');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > maximum) {
        throw const UpdateException('Update response is too large');
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }
}

abstract interface class ManifestSignatureVerifier {
  Future<bool> verify(List<int> message, List<int> signature);
}

class Ed25519ManifestVerifier implements ManifestSignatureVerifier {
  const Ed25519ManifestVerifier();

  @override
  Future<bool> verify(List<int> message, List<int> signature) async {
    final publicKey = GithubUpdateRepository._strictBase64(
      GithubUpdateRepository.publicKeyBase64,
      32,
      'public key',
    );
    return Ed25519().verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  }
}

class _DigestSink implements Sink<hashes.Digest> {
  late hashes.Digest value;

  @override
  void add(hashes.Digest data) => value = data;

  @override
  void close() {}
}
