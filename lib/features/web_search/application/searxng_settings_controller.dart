import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/searxng_search_settings.dart';
import 'searxng_settings_repository.dart';

final searxngSettingsControllerProvider =
    AsyncNotifierProvider<SearxngSettingsController, SearxngSearchSettings>(
      SearxngSettingsController.new,
    );

class SearxngSettingsController extends AsyncNotifier<SearxngSearchSettings> {
  @override
  Future<SearxngSearchSettings> build() =>
      ref.watch(searxngSettingsRepositoryProvider).load();

  Future<void> save(SearxngSearchSettings value, {String? secret}) async {
    final repository = ref.read(searxngSettingsRepositoryProvider);
    await repository.save(value, secret: secret);
    state = AsyncData(await repository.load());
  }

  Future<void> clearSecret() async {
    await ref.read(searxngSettingsRepositoryProvider).clearSecret();
    ref.invalidateSelf();
  }
}
