import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../data/settings_repository.dart';
import '../domain/endpoint_settings.dart';

part 'settings_controller.g.dart';

@riverpod
class SettingsController extends _$SettingsController {
  @override
  Future<EndpointSettings> build() =>
      ref.watch(settingsRepositoryProvider).load();

  Future<void> save({required String baseUrl, String? apiKey}) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final repository = ref.read(settingsRepositoryProvider);
      await repository.save(baseUrl: baseUrl, apiKey: apiKey);
      return repository.load();
    });
  }
}
