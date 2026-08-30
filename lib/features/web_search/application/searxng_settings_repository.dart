import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/storage/app_boxes.dart';
import '../domain/searxng_search_settings.dart';
import 'web_search_policy.dart';

abstract interface class SearchSecretStorage {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

class SecureSearchSecretStorage implements SearchSecretStorage {
  const SecureSearchSecretStorage(this.storage);
  final FlutterSecureStorage storage;
  static const key = 'searxng_bearer_secret';
  @override
  Future<String?> read() => storage.read(key: key);
  @override
  Future<void> write(String value) => storage.write(key: key, value: value);
  @override
  Future<void> clear() => storage.delete(key: key);
}

final searxngSettingsRepositoryProvider = Provider<SearxngSettingsRepository>(
  (_) => SearxngSettingsRepository(
    const SecureSearchSecretStorage(FlutterSecureStorage()),
  ),
);

class SearxngSettingsRepository {
  SearxngSettingsRepository(this.secrets);
  final SearchSecretStorage secrets;
  static const _key = 'searxng_search_settings';
  static const _bindingKey = 'searxng_secret_bound_endpoint';

  Future<SearxngSearchSettings> load() async {
    final raw = preferencesBox.get(_key);
    if (raw is! Map) return const SearxngSearchSettings();
    try {
      final base = WebSearchPolicy.validateBaseUrl(raw['baseUrl'] as String);
      final locale = validateSearchLocale(raw['locale']);
      final range = validateSearchTimeRange(raw['timeRange']);
      final maximum = raw['maxResults'];
      if (maximum is! int || maximum < 1 || maximum > 10) {
        throw const FormatException();
      }
      final acknowledged = raw['httpAcknowledgedUrl'] is String
          ? raw['httpAcknowledgedUrl'] as String
          : null;
      final hasSecret =
          Uri.parse(base).scheme == 'https' &&
          preferencesBox.get(_bindingKey) == base &&
          (await secrets.read())?.isNotEmpty == true;
      final enabled =
          raw['enabled'] == true &&
          (Uri.parse(base).scheme == 'https' || acknowledged == base) &&
          !(Uri.parse(base).scheme == 'http' && hasSecret);
      return SearxngSearchSettings(
        enabled: enabled,
        baseUrl: base,
        locale: locale,
        timeRange: range,
        maxResults: maximum,
        httpAcknowledgedUrl: acknowledged == base ? acknowledged : null,
        hasSecret: hasSecret,
      );
    } on Object {
      return const SearxngSearchSettings();
    }
  }

  Future<void> save(SearxngSearchSettings value, {String? secret}) async {
    final base = WebSearchPolicy.validateBaseUrl(value.baseUrl);
    if (value.enabled &&
        Uri.parse(base).scheme == 'http' &&
        value.httpAcknowledgedUrl != base) {
      throw const WebSearchFailure('http_ack_required');
    }
    final isHttp = Uri.parse(base).scheme == 'http';
    if (isHttp && (secret?.trim().isNotEmpty ?? false)) {
      throw const WebSearchFailure('auth_requires_https');
    }
    if (value.maxResults < 1 || value.maxResults > 10) {
      throw const WebSearchFailure('invalid_max_results');
    }
    final previous = preferencesBox.get(_key);
    final replacement = secret?.trim() ?? '';
    final binding = preferencesBox.get(_bindingKey);
    if (isHttp || (binding != base && replacement.isEmpty)) {
      await preferencesBox.delete(_bindingKey);
      try {
        await secrets.clear();
      } on Object {
        // Missing binding keeps stale secure bytes unusable.
      }
    }
    final next = {
      'enabled': value.enabled,
      'baseUrl': base,
      'locale': validateSearchLocale(value.locale),
      'timeRange': validateSearchTimeRange(value.timeRange),
      'maxResults': value.maxResults,
      'httpAcknowledgedUrl': value.httpAcknowledgedUrl == base
          ? value.httpAcknowledgedUrl
          : null,
    };
    try {
      await preferencesBox.put(_key, next);
      if (!isHttp && replacement.isNotEmpty) {
        await preferencesBox.delete(_bindingKey);
        await secrets.write(replacement);
        await preferencesBox.put(_bindingKey, base);
      }
    } on Object {
      if (previous == null) {
        await preferencesBox.delete(_key);
      } else {
        await preferencesBox.put(_key, previous);
      }
      await preferencesBox.delete(_bindingKey);
      try {
        await secrets.clear();
      } on Object {
        // Fail closed even if secure deletion itself fails.
      }
      rethrow;
    }
  }

  Future<String?> getSecretFor(String endpoint) async {
    final base = WebSearchPolicy.validateBaseUrl(endpoint);
    if (Uri.parse(base).scheme != 'https' ||
        preferencesBox.get(_bindingKey) != base) {
      return null;
    }
    return secrets.read();
  }

  Future<void> clearSecret() async {
    await preferencesBox.delete(_bindingKey);
    await secrets.clear();
  }
}
