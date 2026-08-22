import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/github_update_repository.dart';
import '../data/update_http_client.dart';
import '../data/update_platform_bridge.dart';
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
  });

  final UpdateStatus status;
  final String? currentVersion;
  final UpdateRelease? release;
  final StagedUpdate? staged;
  final String? message;
}

final updatePlatformBridgeProvider = Provider<UpdatePlatformBridge>(
  (_) => MethodChannelUpdatePlatformBridge(),
);

final updateRepositoryProvider = Provider<GithubUpdateRepository>(
  (ref) => GithubUpdateRepository(
    http: DioUpdateHttpClient(),
    platform: ref.watch(updatePlatformBridgeProvider),
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
    required GithubUpdateRepository repository,
    required Future<String> currentVersion,
  }) : _repository = repository,
       _currentVersion = currentVersion,
       super(const UpdateState());

  final GithubUpdateRepository _repository;
  final Future<String> _currentVersion;

  Future<void> check() async {
    state = const UpdateState(status: UpdateStatus.checking);
    try {
      final current = await _currentVersion;
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
      );
    } on Object catch (error) {
      state = UpdateState(
        status: UpdateStatus.failed,
        message: error.toString(),
      );
    }
  }

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
        message: error.toString(),
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
        message: error.toString(),
      );
    }
  }
}
