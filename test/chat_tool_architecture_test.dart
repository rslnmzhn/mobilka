import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'ChatRepository contains transport and context responsibilities only',
    () {
      final source = File(
        'lib/features/chat/data/chat_repository.dart',
      ).readAsStringSync();

      expect(source, isNot(contains('implements ChatToolRuntime')));
      expect(source, isNot(contains('MemoryProposalRuntime')));
      expect(source, isNot(contains('update_memory_file')));
      expect(source, isNot(contains('executeTool')));
      expect(source, isNot(contains('prepareMemoryProposal')));
      expect(source, contains('ContextInjector'));
      expect(source, contains('ChatApiClient'));
    },
  );
}
