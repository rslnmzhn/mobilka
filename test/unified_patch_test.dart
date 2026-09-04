import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/workspace/application/unified_patch.dart';

void main() {
  test('applies exact one-file LF patch and preserves final newline', () {
    final patch = UnifiedPatch.parse(
      '--- notes.md\n+++ notes.md\n@@ -1,2 +1,2 @@\n old\n-sad\n+new\n',
      'notes.md',
    );
    expect(patch.apply('old\nsad\n'), 'old\nnew\n');
  });

  test('rejects fuzzy context, foreign headers and CRLF', () {
    expect(
      () => UnifiedPatch.parse('--- a\n+++ b\n@@ -1 +1 @@\n-a\n+b\n', 'a'),
      throwsFormatException,
    );
    expect(
      () => UnifiedPatch.parse(
        '--- a\r\n+++ a\r\n@@ -1 +1 @@\r\n-a\r\n+b\r\n',
        'a',
      ),
      throwsFormatException,
    );
    final patch = UnifiedPatch.parse(
      '--- a\n+++ a\n@@ -1 +1 @@\n-a\n+b\n',
      'a',
    );
    expect(() => patch.apply('x\n'), throwsFormatException);
  });
}
