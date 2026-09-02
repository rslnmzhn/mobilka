import 'dart:convert';
import 'dart:math';

import 'package:synchronized/synchronized.dart';

import '../domain/staged_update_metadata.dart';
import '../domain/update_manifest.dart';
import '../domain/update_release.dart';
import '../domain/version_number.dart';
import 'manifest_signature_verifier.dart';
import 'staged_update_store.dart';
import 'update_http_client.dart';
import 'update_platform_bridge.dart';

class UpdateStagingLifecycleCoordinator {
  UpdateStagingLifecycleCoordinator({
    required UpdatePlatformBridge platform,
    required StagedUpdateStore store,
    required ManifestSignatureVerifier verifier,
    DateTime Function()? clock,
    UpdateCleanupPolicy policy = const UpdateCleanupPolicy(),
  }) : _platform = platform,
       _store = store,
       _verifier = verifier,
       _clock = clock ?? DateTime.now,
       _policy = policy;

  final UpdatePlatformBridge _platform;
  StagedUpdateFilesystem get _files => _platform;
  final StagedUpdateStore _store;
  final ManifestSignatureVerifier _verifier;
  final DateTime Function() _clock;
  final UpdateCleanupPolicy _policy;
  final Lock _lock = Lock();

  Future<StagedUpdate> stage(
    UpdateRelease release,
    UpdateHttpResponse response,
  ) => _lock.synchronized(() => _stage(release, response));

  Future<StagedUpdate> _stage(
    UpdateRelease release,
    UpdateHttpResponse response,
  ) async {
    final bound = await _validateRelease(release);
    final existing = await _store.load();
    if (existing != null &&
        existing.version == release.version &&
        await _verified(existing) != null) {
      await _cleanup(existing);
      return _projection(existing, bound);
    }
    await _cleanup(null);
    if (response.contentLength != null &&
        response.contentLength != release.asset.size) {
      throw const UpdateException('Installer size does not match manifest');
    }
    final nonce = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    final name =
        'mobilka-${release.version}-${release.asset.platform}-${release.asset.architecture}-$nonce.${release.asset.format}';
    final now = _clock().toUtc();
    var metadata = StagedUpdateMetadata(
      lifecycle: StagedUpdateLifecycle.downloading,
      platform: release.asset.platform,
      format: release.asset.format,
      version: release.version,
      versionCode: release.asset.versionCode,
      expectedSize: release.asset.size,
      sha256: release.asset.sha256,
      fileName: name,
      partialName: '$name.part',
      createdAt: now,
      updatedAt: now,
      attemptCount: 0,
      manifestBase64: base64.encode(release.proof!.manifestBytes),
      signatureBase64: base64.encode(release.proof!.signatureBytes),
    );
    await _store.save(metadata);
    SafeDownloadSink? sink;
    Object? originalError;
    try {
      sink = await _files.beginDownload(metadata.partialName);
      var received = 0;
      await for (final chunk in response.stream) {
        received += chunk.length;
        if (received > release.asset.size) {
          throw const UpdateException('Installer exceeds declared size');
        }
        await sink.write(chunk);
      }
      await sink.finish();
      sink = null;
      if (received != release.asset.size) {
        throw const UpdateException('Installer integrity check failed');
      }
      metadata = metadata.transition(
        StagedUpdateLifecycle.finalizing,
        _clock(),
      );
      await _store.save(metadata);
      final finalFile = await _files.importVerifiedDownload(
        metadata.partialName,
        metadata.fileName,
        metadata.expectedSize,
        metadata.sha256,
      );
      metadata = metadata.transition(
        StagedUpdateLifecycle.verified,
        _clock(),
        fileIdentity: finalFile.identityToken,
      );
      await _store.save(metadata);
      return _projection(metadata, bound);
    } catch (error) {
      originalError = error;
      // Persisted metadata remains recovery authority. Never use an untrusted path.
      rethrow;
    } finally {
      try {
        if (originalError != null) await sink?.abort();
      } on Object {
        if (originalError == null) rethrow;
      }
    }
  }

  Future<StagedUpdate?> recoverThenCheck(String installedVersion) =>
      _lock.synchronized(() async {
        final target = await _platform.target();
        if (target.platform == UpdatePlatform.unsupported) return null;
        final metadata = await _store.load();
        if (metadata == null) {
          await _cleanup(null);
          return null;
        }
        final release = await _releaseFromProof(metadata);
        if (release == null) {
          await _store.clear();
          await _cleanup(null);
          return null;
        }
        final installed = metadata.platform == 'android'
            ? await _platform.installedVersionCode()
            : null;
        final alreadyInstalled = metadata.platform == 'android'
            ? installed != null && installed >= metadata.versionCode!
            : VersionNumber.parse(
                    installedVersion,
                  ).compareTo(VersionNumber.parse(metadata.version)) >=
                  0;
        if (alreadyInstalled) {
          final finalFile = await _verified(metadata);
          if (finalFile != null) {
            await _delete(finalFile);
          }
          final part = await _files.verifyStaged(
            metadata.partialName,
            metadata.expectedSize,
            metadata.sha256,
          );
          if (part != null) await _delete(part);
          await _store.clear();
          if (metadata.platform == 'windows') {
            await _platform.rotateWindowsHandoffLog();
          }
          await _cleanup(null);
          return null;
        }
        var current = metadata;
        if (current.lifecycle == StagedUpdateLifecycle.finalizing) {
          final finalFile = await _files.verifyStaged(
            current.fileName,
            current.expectedSize,
            current.sha256,
          );
          if (finalFile != null) {
            current = current.transition(
              StagedUpdateLifecycle.verified,
              _clock(),
              fileIdentity: finalFile.identityToken,
            );
          } else {
            await _store.clear();
            await _cleanup(null);
            return null;
          }
          await _store.save(current);
        }
        if (current.lifecycle == StagedUpdateLifecycle.downloading ||
            await _verified(current) == null) {
          await _store.clear();
          await _cleanup(null);
          return null;
        }
        await _cleanup(current);
        if (await _verified(current) == null) {
          await _store.clear();
          return null;
        }
        return _projection(current, release);
      });

  Future<bool> apply(StagedUpdate projection) => _lock.synchronized(() async {
    var metadata = await _store.load();
    if (metadata == null || projection.id != _id(metadata)) {
      throw const UpdateException('Verified staged update is unavailable');
    }
    final release = await _releaseFromProof(metadata);
    if (release == null) {
      throw const UpdateException('Signed update binding is invalid');
    }
    final verified = await _verified(metadata);
    if (verified == null) {
      throw const UpdateException('Verified staged update is unavailable');
    }
    final target = await _platform.target();
    if ((target.platform == UpdatePlatform.android ? 'android' : 'windows') !=
        metadata.platform) {
      throw const UpdateException('Staged update platform mismatch');
    }
    if (target.platform == UpdatePlatform.android) {
      metadata = metadata.transition(
        StagedUpdateLifecycle.permissionRequired,
        _clock(),
        applying: true,
      );
      await _store.save(metadata);
      final launched = await _platform.installAndroidApk(
        verified.basename,
        release.asset,
        identityToken: verified.identityToken,
      );
      await _store.save(
        metadata.transition(
          launched
              ? StagedUpdateLifecycle.installerLaunched
              : StagedUpdateLifecycle.permissionRequired,
          _clock(),
        ),
      );
      return launched;
    }
    if (target.platform == UpdatePlatform.windows) {
      if (!await _platform.isWindowsMsiInstalled()) return false;
      await _store.save(
        metadata.transition(
          StagedUpdateLifecycle.handoffStarted,
          _clock(),
          applying: true,
        ),
      );
      await _platform.installWindowsMsi(
        verified.basename,
        verified.size,
        verified.sha256,
        identityToken: verified.identityToken,
      );
      return true;
    }
    throw const UpdateException('Updates are not supported on this platform');
  });

  Future<UpdateRelease> _validateRelease(UpdateRelease release) async {
    final proof = release.proof;
    if (proof == null ||
        proof.signatureBytes.length != 64 ||
        !await _verifier.verify(proof.manifestBytes, proof.signatureBytes)) {
      throw const UpdateException('Signed update binding is invalid');
    }
    final selected = UpdateManifest.parse(
      proof.manifestBytes,
    ).select(await _platform.target());
    if (!_same(release, selected)) {
      throw const UpdateException('Release differs from signed manifest');
    }
    return selected;
  }

  Future<UpdateRelease?> _releaseFromProof(
    StagedUpdateMetadata metadata,
  ) async {
    try {
      final proof = StagedUpdateProof(
        manifestBytes: base64.decode(metadata.manifestBase64),
        signatureBytes: base64.decode(metadata.signatureBase64),
      );
      if (proof.signatureBytes.length != 64 ||
          !await _verifier.verify(proof.manifestBytes, proof.signatureBytes)) {
        return null;
      }
      final release = UpdateManifest.parse(
        proof.manifestBytes,
      ).select(await _platform.target());
      return _matchesMetadata(release, metadata) ? release : null;
    } on Object {
      return null;
    }
  }

  bool _same(UpdateRelease a, UpdateRelease b) =>
      a.version == b.version &&
      a.tag == b.tag &&
      a.asset.platform == b.asset.platform &&
      a.asset.architecture == b.asset.architecture &&
      a.asset.format == b.asset.format &&
      a.asset.size == b.asset.size &&
      a.asset.sha256 == b.asset.sha256 &&
      a.asset.versionCode == b.asset.versionCode &&
      a.asset.applicationId == b.asset.applicationId &&
      a.asset.downloadUri == b.asset.downloadUri;
  bool _matchesMetadata(UpdateRelease r, StagedUpdateMetadata m) =>
      r.version == m.version &&
      r.asset.platform == m.platform &&
      r.asset.format == m.format &&
      r.asset.size == m.expectedSize &&
      r.asset.sha256 == m.sha256 &&
      r.asset.versionCode == m.versionCode;
  Future<VerifiedStagedFileIdentity?> _verified(StagedUpdateMetadata m) =>
      _files.verifyStaged(
        m.fileName,
        m.expectedSize,
        m.sha256,
        identityToken: m.fileIdentity,
      );
  String _id(StagedUpdateMetadata m) =>
      '${m.version}:${m.fileName}:${m.sha256}';
  StagedUpdate _projection(StagedUpdateMetadata m, UpdateRelease r) =>
      StagedUpdate(id: _id(m), release: r);

  Future<void> _cleanup(StagedUpdateMetadata? protected) async {
    final files = (await _platform.safeListStaged()).toList();
    final now = _clock().toUtc();
    final parts = files.where((f) => f.basename.endsWith('.part')).toList()
      ..sort((a, b) {
        final c = b.modifiedMillis.compareTo(a.modifiedMillis);
        return c != 0 ? c : a.basename.compareTo(b.basename);
      });
    for (var i = 0; i < parts.length; i++) {
      final f = parts[i];
      final stale =
          now.difference(
            DateTime.fromMillisecondsSinceEpoch(f.modifiedMillis, isUtc: true),
          ) >=
          _policy.staleParts;
      if (stale || i >= _policy.maxCurrentParts) {
        await _platform.safeDeleteStaged(
          f.basename,
          f.size,
          f.sha256,
          identityToken: f.identityToken,
        );
      }
    }
    final finals = files.where((f) => !f.basename.endsWith('.part')).toList()
      ..sort((a, b) {
        final c = b.modifiedMillis.compareTo(a.modifiedMillis);
        return c != 0 ? c : a.basename.compareTo(b.basename);
      });
    var keptUnprotected = 0;
    for (final f in finals) {
      final isProtected = f.basename == protected?.fileName;
      final age = now.difference(
        DateTime.fromMillisecondsSinceEpoch(f.modifiedMillis, isUtc: true),
      );
      final expired =
          age >=
          (isProtected ? _policy.protectedRetry : _policy.unprotectedFinals);
      final over =
          !isProtected &&
          keptUnprotected >=
              (_policy.maxFinals - (protected == null ? 0 : 1)).clamp(
                0,
                _policy.maxFinals,
              );
      if (expired || over) {
        await _platform.safeDeleteStaged(
          f.basename,
          f.size,
          f.sha256,
          identityToken: f.identityToken,
        );
        if (isProtected) await _store.clear();
      } else if (!isProtected) {
        keptUnprotected++;
      }
    }
  }

  Future<void> _delete(VerifiedStagedFileIdentity file) =>
      _platform.safeDeleteStaged(
        file.basename,
        file.size,
        file.sha256,
        identityToken: file.identityToken,
      );
}

class UpdateCleanupPolicy {
  const UpdateCleanupPolicy({
    this.staleParts = const Duration(hours: 24),
    this.unprotectedFinals = const Duration(days: 7),
    this.protectedRetry = const Duration(days: 30),
    this.maxFinals = 2,
    this.maxCurrentParts = 1,
  });
  final Duration staleParts, unprotectedFinals, protectedRetry;
  final int maxFinals, maxCurrentParts;
}
