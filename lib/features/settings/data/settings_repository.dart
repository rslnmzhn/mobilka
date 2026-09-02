import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/network/endpoint_policy.dart';
import '../../../core/storage/app_boxes.dart';
import '../domain/endpoint_settings.dart';

part 'settings_repository.g.dart';

@Riverpod(keepAlive: true)
SettingsRepository settingsRepository(Ref ref) =>
    SettingsRepository(const FlutterSecureStorage());

class SettingsRepository {
  SettingsRepository(this._secureStorage);
  static const _apiKeyStorageKey = 'openai_compatible_api_key';
  final FlutterSecureStorage _secureStorage;

  Future<EndpointSettings> load() async {
    final storedBaseUrl =
        preferencesBox.get('baseUrl', defaultValue: '') as String;
    final baseUrl = storedBaseUrl.isEmpty ? '' : validateBaseUrl(storedBaseUrl);
    return EndpointSettings(
      baseUrl: baseUrl,
      hasApiKey: (await _readSecret())?.isNotEmpty ?? false,
    );
  }

  Future<void> save({required String baseUrl, String? apiKey}) async {
    final validatedBaseUrl = validateBaseUrl(baseUrl);
    await preferencesBox.put('baseUrl', validatedBaseUrl);
    if (apiKey != null && apiKey.trim().isNotEmpty) {
      await _secureStorage.write(key: _apiKeyStorageKey, value: apiKey.trim());
    }
  }

  String validateBaseUrl(String baseUrl) {
    return validateEndpointBaseUrl(baseUrl);
  }

  Future<String?> readApiKey() => _readSecret();

  Future<String?> _readSecret() async {
    try {
      return await _secureStorage.read(key: _apiKeyStorageKey);
    } on UnsupportedError catch (error, stackTrace) {
      throw SettingsSecretUnavailableException(error, stackTrace);
    }
  }
}

class SettingsSecretUnavailableException implements Exception {
  const SettingsSecretUnavailableException(this.cause, this.causeStackTrace);

  final UnsupportedError cause;
  final StackTrace causeStackTrace;
}
