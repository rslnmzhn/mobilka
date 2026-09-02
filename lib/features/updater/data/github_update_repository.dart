import 'dart:convert';

import '../domain/update_manifest.dart';
import '../domain/update_release.dart';
import 'staged_update_store.dart';
import 'manifest_signature_verifier.dart';
import 'update_http_client.dart';
import 'update_platform_bridge.dart';
import 'update_staging_lifecycle_coordinator.dart';

export 'manifest_signature_verifier.dart';
export 'staged_update_store.dart';
export 'update_staging_lifecycle_coordinator.dart' show UpdateCleanupPolicy;

abstract interface class UpdateRepository {
  Future<UpdateRelease> latest();
  Future<StagedUpdate> download(UpdateRelease release);
  Future<bool> apply(StagedUpdate projection);
  Future<StagedUpdate?> recover(String installedVersion);
}

/// Network discovery and installer fetching only. Staging state and IO belong
/// to [UpdateStagingLifecycleCoordinator].
class GithubUpdateRepository implements UpdateRepository {
  GithubUpdateRepository({
    required UpdateHttpClient http,
    required UpdatePlatformBridge platform,
    ManifestSignatureVerifier? signatureVerifier,
    StagedUpdateStore? stagedStore,
    DateTime Function()? clock,
    UpdateCleanupPolicy policy = const UpdateCleanupPolicy(),
  }) : _http = http,
       _platform = platform,
       _verifier = signatureVerifier ?? const Ed25519ManifestVerifier(),
       _lifecycle = UpdateStagingLifecycleCoordinator(
         platform: platform,
         store: stagedStore ?? MemoryStagedUpdateStore(),
         verifier: signatureVerifier ?? const Ed25519ManifestVerifier(),
         clock: clock,
         policy: policy,
       );

  static final latestReleaseUri = Uri.https(
    'api.github.com',
    '/repos/rslnmzhn/mobilka/releases/latest',
  );
  static const publicKeyBase64 = updateManifestPublicKeyBase64;

  final UpdateHttpClient _http;
  final UpdatePlatformBridge _platform;
  final ManifestSignatureVerifier _verifier;
  final UpdateStagingLifecycleCoordinator _lifecycle;

  @override
  Future<UpdateRelease> latest() async {
    final metadata = jsonDecode(
      utf8.decode(
        await _read(
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
    final manifests = assets.whereType<Map>().where(
      (a) =>
          a['name'] is String &&
          RegExp(
            r'^mobilka-v\d+\.\d+\.\d+-release-manifest\.json$',
          ).hasMatch(a['name'] as String),
    );
    if (manifests.length != 1) {
      throw const UpdateException('Release has no unique update manifest');
    }
    final manifestAsset = manifests.single;
    final manifestName = manifestAsset['name'] as String;
    final signatureName =
        '${manifestName.substring(0, manifestName.length - 5)}.sig';
    final signatures = assets.whereType<Map>().where(
      (a) => a['name'] == signatureName,
    );
    if (signatures.length != 1) {
      throw const UpdateException('Release has no unique manifest signature');
    }
    final manifestBytes = await _read(
      await _http.get(_assetUri(manifestAsset)),
      UpdateLimits.maxManifestBytes,
    );
    final signatureBytes = await _read(
      await _http.get(_assetUri(signatures.single)),
      UpdateLimits.maxSignatureBytes,
    );
    if (signatureBytes.length != 64 ||
        !await _verifier.verify(manifestBytes, signatureBytes)) {
      throw const UpdateException('Manifest signature is invalid');
    }
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
    final selected = manifest.select(await _platform.target());
    return UpdateRelease(
      version: selected.version,
      tag: selected.tag,
      asset: selected.asset,
      proof: StagedUpdateProof(
        manifestBytes: manifestBytes,
        signatureBytes: signatureBytes,
      ),
    );
  }

  @override
  Future<StagedUpdate> download(UpdateRelease release) async {
    if (release.proof == null) {
      throw const UpdateException('Update has no signed manifest binding');
    }
    final response = await _http.get(release.asset.downloadUri);
    return _lifecycle.stage(release, response);
  }

  @override
  Future<bool> apply(StagedUpdate projection) => _lifecycle.apply(projection);

  @override
  Future<StagedUpdate?> recover(String installedVersion) =>
      _lifecycle.recoverThenCheck(installedVersion);

  static Uri _assetUri(Map<dynamic, dynamic> asset) {
    final uri = asset['browser_download_url'] is String
        ? Uri.tryParse(asset['browser_download_url'] as String)
        : null;
    if (uri == null) {
      throw const UpdateException('Release asset URL is invalid');
    }
    return uri;
  }

  static Future<List<int>> _read(
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
