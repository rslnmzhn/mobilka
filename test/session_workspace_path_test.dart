import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/workspace/domain/session_workspace_path.dart';

void main() {
  test('accepts portable relative UTF-8 paths', () {
    expect(SessionWorkspacePath.parse('docs/тест.md').value, 'docs/тест.md');
    expect(SessionWorkspacePath.parse('', allowRoot: true).components, isEmpty);
  });

  test('rejects traversal, separators, roots, controls and reserved names', () {
    for (final value in [
      '',
      '/a',
      'a/',
      'a//b',
      '.',
      '..',
      'a/../b',
      '.mobilka-workspace',
      'a/.hidden',
      r'a\b',
      'C:file',
      r'\\server',
      'con',
      'NUL.txt',
      'COM9.log',
      'LPT1',
      'file.',
      'file ',
      'a\u0000b',
      'a\u001fb',
    ]) {
      expect(
        () => SessionWorkspacePath.parse(value),
        throwsFormatException,
        reason: value,
      );
    }
  });

  test('enforces component, depth and total UTF-8 limits', () {
    expect(
      () => SessionWorkspacePath.parse('${'a' * 129}.md'),
      throwsFormatException,
    );
    expect(
      () => SessionWorkspacePath.parse(List.filled(17, 'a').join('/')),
      throwsFormatException,
    );
    expect(
      () => SessionWorkspacePath.parse(List.filled(9, 'x' * 120).join('/')),
      throwsFormatException,
    );
  });
}
