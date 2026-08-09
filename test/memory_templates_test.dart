import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';

void main() {
  test('memory templates contain all source-of-truth files', () {
    expect(
      MemoryRepository.templates.keys,
      containsAll([
        'user_profile.md',
        'project_context.md',
        'system_instructions.md',
        'memory_log.md',
      ]),
    );
  });
}
