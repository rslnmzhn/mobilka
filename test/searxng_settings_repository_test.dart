import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/web_search/application/searxng_settings_repository.dart';
import 'package:mobilka/features/web_search/domain/searxng_search_settings.dart';

void main() {
  late Directory directory;
  late _Secrets secrets;
  late SearxngSettingsRepository repository;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('searxng-settings-');
    Hive.init(directory.path);
    await Hive.openBox<dynamic>('preferences');
    secrets = _Secrets();
    repository = SearxngSettingsRepository(secrets);
  });
  tearDown(() async {
    await Hive.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'secret is returned only for exact bound canonical HTTPS endpoint',
    () async {
      await repository.save(
        _settings('https://one.example/api'),
        secret: 'key',
      );
      expect(await repository.getSecretFor('https://one.example/api'), 'key');
      expect(await repository.getSecretFor('https://two.example/api'), isNull);
      expect((await repository.load()).hasSecret, isTrue);
    },
  );

  test(
    'HTTPS endpoint change without replacement clears secret and binding',
    () async {
      await repository.save(_settings('https://one.example'), secret: 'key');
      await repository.save(_settings('https://two.example'));
      expect(secrets.value, isNull);
      expect(await repository.getSecretFor('https://one.example'), isNull);
      expect((await repository.load()).hasSecret, isFalse);
    },
  );

  test('HTTP save clears secret and never exposes authentication', () async {
    await repository.save(_settings('https://one.example'), secret: 'key');
    await repository.save(_settings('http://two.example', http: true));
    expect(secrets.value, isNull);
    expect(await repository.getSecretFor('http://two.example'), isNull);
  });

  test(
    'canonical HTTP endpoint and acknowledgement accept normalized input',
    () async {
      const canonical = 'http://example.com/api';
      await repository.save(
        const SearxngSearchSettings(
          enabled: true,
          baseUrl: 'HTTP://Example.COM:80/api/',
          httpAcknowledgedUrl: canonical,
        ),
      );
      final loaded = await repository.load();
      expect(loaded.baseUrl, canonical);
      expect(loaded.httpAcknowledged, isTrue);
      expect(loaded.enabled, isTrue);
    },
  );

  test('secure write failure leaves no binding or readable secret', () async {
    secrets.failWrite = true;
    await expectLater(
      repository.save(_settings('https://one.example'), secret: 'key'),
      throwsStateError,
    );
    expect(await repository.getSecretFor('https://one.example'), isNull);
    expect((await repository.load()).hasSecret, isFalse);
  });
}

SearxngSearchSettings _settings(String base, {bool http = false}) =>
    SearxngSearchSettings(
      enabled: true,
      baseUrl: base,
      httpAcknowledgedUrl: http ? base : null,
    );

class _Secrets implements SearchSecretStorage {
  String? value;
  bool failWrite = false;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    if (failWrite) throw StateError('write failed');
    this.value = value;
  }
}
