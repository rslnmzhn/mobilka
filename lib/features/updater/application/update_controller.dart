import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/github_update_repository.dart';
import '../data/update_http_client.dart';
import '../data/update_platform_bridge.dart';
import '../../../core/storage/app_boxes.dart';
import '../domain/update_release.dart';
import '../domain/version_number.dart';

enum UpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  downloaded,
  permissionRequired,
  applying,
  failed,
}

class UpdateState {
  const UpdateState({
    this.status = UpdateStatus.idle,
    this.currentVersion,
    this.release,
    this.staged,
    this.message,
    this.messageKey,
  });

  final UpdateStatus status;
  final String? currentVersion;
  final UpdateRelease? release;
  final StagedUpdate? staged;
  final String? message;
  final String? messageKey;
}

final updatePlatformBridgeProvider = Provider<UpdatePlatformBridge>(
  (_) => MethodChannelUpdatePlatformBridge(),
);

final updateRepositoryProvider = Provider<GithubUpdateRepository>(
  (ref) => GithubUpdateRepository(
    http: DioUpdateHttpClient(),
    platform: ref.watch(updatePlatformBridgeProvider),
    stagedStore: HiveStagedUpdateStore(preferencesBox),
  ),
);

final currentAppVersionProvider = Provider<Future<String>>(
  (_) async =>
      const String.fromEnvironment('MOBILKA_VERSION', defaultValue: '0.0.1'),
);

final updateControllerProvider =
    StateNotifierProvider<UpdateController, UpdateState>(
      (ref) => UpdateController(
        repository: ref.watch(updateRepositoryProvider),
        currentVersion: ref.watch(currentAppVersionProvider),
      ),
    );

class UpdateController extends StateNotifier<UpdateState> {
  UpdateController({
    required UpdateRepository repository,
    required Future<String> currentVersion,
  }) : _repository = repository,
       _currentVersion = currentVersion,
       super(const UpdateState());

  final UpdateRepository _repository;
  final Future<String> _currentVersion;
  bool _recoveryRunning = false;
  Future<void> recoverThenCheck() async {
    if (_recoveryRunning) return;
    _recoveryRunning = true;
    final current = await _currentVersion;
    try {
      final staged = await _repository.recover(current);
      if (staged != null) {
        state = UpdateState(
          currentVersion: current,
          staged: staged,
          message: 'A verified installer was recovered and is ready to retry.',
        );
      }
    } finally {
      _recoveryRunning = false;
    }
  }

  Future<void> check() async {
    final recovered = state.staged;
    state = UpdateState(status: UpdateStatus.checking, staged: recovered);
    try {
      final current = await _currentVersion;
      StagedUpdate? staged;
      try {
        staged = await _repository.recover(current);
      } on Object {
        // Recovery is best-effort; discovery must remain available.
        staged = recovered;
      }
      final release = await _repository.latest();
      final available =
          VersionNumber.parse(
            release.version,
          ).compareTo(VersionNumber.parse(current)) >
          0;
      state = UpdateState(
        status: available ? UpdateStatus.available : UpdateStatus.upToDate,
        currentVersion: current,
        release: available ? release : null,
        staged: staged,
        message: staged == null
            ? null
            : 'A verified installer was recovered and is ready to retry.',
      );
    } on Object catch (error) {
      state = UpdateState(
        status: UpdateStatus.failed,
        staged: state.staged,
        message: _safeUpdateError(error),
        messageKey: _updateErrorKey(error),
      );
    }
  }

  @Deprecated('Use check; retained for startup compatibility')
  Future<void> recover() => recoverThenCheck();

  Future<void> downloadAndApply() async {
    final release = state.release;
    if (release == null) return;
    state = UpdateState(
      status: UpdateStatus.downloading,
      currentVersion: state.currentVersion,
      release: release,
    );
    try {
      final staged = await _repository.download(release);
      state = UpdateState(
        status: UpdateStatus.applying,
        currentVersion: state.currentVersion,
        release: release,
        staged: staged,
      );
      final applied = await _repository.apply(staged);
      state = UpdateState(
        status: applied
            ? UpdateStatus.downloaded
            : UpdateStatus.permissionRequired,
        currentVersion: state.currentVersion,
        release: release,
        staged: staged,
        message: applied
            ? 'Installer opened. Complete the platform installation prompts.'
            : 'Grant installation permission, then press Install again.',
      );
    } on Object catch (error) {
      state = UpdateState(
        status: UpdateStatus.failed,
        currentVersion: state.currentVersion,
        release: release,
        staged: state.staged,
        message: _safeUpdateError(error),
        messageKey: _updateErrorKey(error),
      );
    }
  }

  Future<void> retryInstall() async {
    final staged = state.staged;
    if (staged == null) return;
    state = UpdateState(
      status: UpdateStatus.applying,
      currentVersion: state.currentVersion,
      release: state.release,
      staged: staged,
    );
    try {
      final applied = await _repository.apply(staged);
      state = UpdateState(
        status: applied
            ? UpdateStatus.downloaded
            : UpdateStatus.permissionRequired,
        currentVersion: state.currentVersion,
        release: state.release,
        staged: staged,
        message: applied
            ? 'Installer opened. Complete the platform installation prompts.'
            : 'Installation permission is still required.',
      );
    } on Object catch (error) {
      state = UpdateState(
        status: UpdateStatus.failed,
        currentVersion: state.currentVersion,
        release: state.release,
        staged: staged,
        message: _safeUpdateError(error),
        messageKey: _updateErrorKey(error),
      );
    }
  }
}

String? _updateErrorKey(Object error) {
  if (error is UpdateInstallException) {
    return error.failure == UpdateInstallFailure.providerScopeUnavailable
        ? 'updater.providerScopeUnavailable'
        : 'updater.installFailed';
  }
  return null;
}

String? _safeUpdateError(Object error) =>
    _updateErrorKey(error) == null ? error.toString() : null;
