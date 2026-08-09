import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/core/network/endpoint_policy.dart';

void main() {
  group('endpoint validation', () {
    test('accepts remote HTTP endpoint', () {
      expect(
        validateEndpointBaseUrl('http://192.0.2.10:20129/v1/'),
        'http://192.0.2.10:20129/v1',
      );
    });

    test('accepts HTTPS and local endpoints', () {
      expect(
        validateEndpointBaseUrl('https://api.example.com/v1'),
        'https://api.example.com/v1',
      );
      expect(
        validateEndpointBaseUrl('http://10.0.2.2:8080/v1'),
        'http://10.0.2.2:8080/v1',
      );
    });

    test('rejects malformed and unsafe URL forms', () {
      expect(
        () => validateEndpointBaseUrl('192.0.2.10:20129/v1'),
        throwsFormatException,
      );
      expect(
        () => validateEndpointBaseUrl('ftp://example.com/v1'),
        throwsFormatException,
      );
      expect(
        () => validateEndpointBaseUrl('https://user@example.com/v1'),
        throwsFormatException,
      );
      expect(
        () => validateEndpointBaseUrl('https://example.com/v1?q=1'),
        throwsFormatException,
      );
    });
  });

  test('joins models path without duplicating v1', () {
    expect(
      endpointResourceUri('http://192.0.2.10:20129/v1', 'models').toString(),
      'http://192.0.2.10:20129/v1/models',
    );
  });

  test('joins nested chat completions path', () {
    expect(
      endpointResourceUri(
        'http://192.0.2.10:20129/v1',
        'chat/completions',
      ).toString(),
      'http://192.0.2.10:20129/v1/chat/completions',
    );
  });

  test(
    'attaches API key to explicitly configured HTTP and disables redirects',
    () {
      final httpHeaders = endpointAuthorizationHeaders(
        endpoint: Uri.parse('http://192.0.2.10:20129/v1/models'),
        apiKey: 'secret',
      );
      expect(httpHeaders, {'Authorization': 'Bearer secret'});
      expect(endpointRequestMayFollowRedirects(httpHeaders), isFalse);

      final httpsHeaders = endpointAuthorizationHeaders(
        endpoint: Uri.parse('https://api.example.com/v1/models'),
        apiKey: 'secret',
      );
      expect(httpsHeaders, {'Authorization': 'Bearer secret'});
      expect(endpointRequestMayFollowRedirects(httpsHeaders), isFalse);
      expect(endpointRequestMayFollowRedirects(const {}), isTrue);
    },
  );
}
