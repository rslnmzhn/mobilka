import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/core/links/external_link_policy.dart';

void main() {
  const policy = ExternalLinkPolicy();
  test('accepts and canonicalizes absolute web URLs', () {
    expect(
      policy.canonicalize('https://Example.COM:443?q=1#part').toString(),
      'https://example.com/?q=1#part',
    );
    expect(
      policy.canonicalize('http://127.0.0.1:80').toString(),
      'http://127.0.0.1/',
    );
  });
  test('rejects non-web, relative, ambiguous and oversized URLs', () {
    for (final value in [
      '',
      '/relative',
      '//example.com/a',
      '#part',
      'file:///tmp/a',
      'content://authority/a',
      'data:text/plain,a',
      'javascript:alert(1)',
      'mailto:a@example.com',
      'custom://example.com',
      'https://user@example.com',
      'https://example.com./',
      'https://éxample.com/',
      'https://example.com/a b',
      'https://example.com\\a',
      'https://example.com/\u007f',
      'https://${'a' * 8200}.com',
      'https://example%2ecom/',
      'https://example.com%40evil.test/',
      'https://example.com%2f.evil.test/',
      'https://example.com%5c.evil.test/',
      'https://example.com%0a.evil.test/',
      'https://example.com/%zz',
      'https://example.com:abc/',
      'https://example.com:0/',
      'https://example.com:65536/',
      'https://a..b/',
      'https://-bad.example/',
      'https://bad-.example/',
      'https://bad_host.example/',
      'https://${'a' * 64}.example/',
      'https://127.1/',
      'https://127.0.0.01/',
      'https://0x7f000001/',
      'https://017700000001/',
      'https://::1/',
      'https://[not-ip]/',
    ]) {
      expect(policy.canonicalize(value), isNull, reason: value);
    }
  });
}
