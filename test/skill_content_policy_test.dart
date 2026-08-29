import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/skill_content_policy.dart';

void main() {
  const policy = SkillContentPolicy();
  const valid = '''
## Trigger
Need current time for a location and timezone.
## Procedure
Resolve timezone, query a verified time source, then use a fallback source.
## Validate
Check source freshness and timezone offset.
## Fallbacks
Use a second verified source and report inability if both fail.
## Safety
Never retain the observed timestamp or user secrets.
''';

  test('accepts a stable time method without retaining current value', () {
    expect(policy.validate(valid).warnings, isEmpty);
  });

  test('rejects missing contract sections, raw source and obvious secrets', () {
    expect(() => policy.validate('# Trigger\nonly'), throwsFormatException);
    expect(
      () => policy.validate(
        valid.replaceFirst('Need current', '<untrusted_public_source>'),
      ),
      throwsFormatException,
    );
    expect(
      () => policy.validate('$valid\napi_key=abcdefghijklmnopqrstuvwxyz123456'),
      throwsFormatException,
    );
  });

  test('rejects common synthetic credential forms', () {
    for (final secret in [
      'glpat-abcdefghijklmnopqrst',
      'ghp_abcdefghijklmnopqrstuvwxyz1234',
      'github_pat_abcdefghijklmnopqrstuvwxyz1234',
      'sk-abcdefghijklmnopqrstuvwxyz123456',
      'AKIAABCDEFGHIJKLMNOP',
      'ASIAABCDEFGHIJKLMNOP',
      'xoxb-123456789012345678901234',
      'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature123',
      'AIzaabcdefghijklmnopqrstuvwxyz12345678',
      '-----BEGIN PRIVATE KEY-----',
      'Bearer abcdefghijklmnopqrstuvwxyz',
      'Basic YWxhZGRpbjpvcGVuc2VzYW1l',
      'password=abcdefghijklmnopqrstuvwxyz',
      'https://user:password@example.com/',
    ]) {
      expect(
        () => policy.validate('$valid\n$secret'),
        throwsFormatException,
        reason: secret,
      );
    }
  });
}
