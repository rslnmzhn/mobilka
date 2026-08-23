import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/updater/data/update_http_client.dart';
import 'package:mobilka/features/updater/domain/update_release.dart';

void main() {
  group('UpdateHttpClient approved hosts', () {
    test('accepts github api and download hosts', () {
      for (final host in [
        'api.github.com',
        'github.com',
        'objects.githubusercontent.com',
        'github-releases.githubusercontent.com',
      ]) {
        expect(
          () => DioUpdateHttpClient.validateUriForTest(
            Uri.parse('https://$host/path'),
          ),
          returnsNormally,
          reason: host,
        );
      }
    });

    test('accepts the 2025 release-assets cdn host', () {
      // GitHub now redirects release downloads to this host; without it the
      // updater fails with "Update URL is not approved".
      expect(
        () => DioUpdateHttpClient.validateUriForTest(
          Uri.parse(
            'https://release-assets.githubusercontent.com/uranium/asset',
          ),
        ),
        returnsNormally,
      );
    });

    test('rejects foreign hosts and non-https', () {
      for (final uri in [
        Uri.parse('https://evil.example.com/asset'),
        Uri.parse('http://github.com/asset'),
        Uri.parse('https://github.com:8443/asset'),
        Uri.parse('https://user@github.com/asset'),
      ]) {
        expect(
          () => DioUpdateHttpClient.validateUriForTest(uri),
          throwsA(isA<UpdateException>()),
          reason: '$uri',
        );
      }
    });
  });
}
