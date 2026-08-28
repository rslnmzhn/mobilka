import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/core/logging/app_logger.dart';

void main() {
  test('structured entries expose only the approved operational fields', () {
    final entries = <AppLogEntry>[];
    final logger = AppLogger(
      sink: entries.add,
      now: () => DateTime.utc(2026, 8, 17),
    );

    logger.log(
      event: 'memory.apply',
      operationId: 'operation-1',
      conversationId: 'conversation-1',
      toolCallId: 'tool-1',
      fileName: 'user.md',
      status: 'failed',
      error: StateError('secret proposed content and confirmation token'),
      duration: const Duration(milliseconds: 12),
    );

    final encoded = entries.single.toString();
    expect(encoded, contains('StateError'));
    expect(encoded, isNot(contains('operation-1')));
    expect(encoded, isNot(contains('conversation-1')));
    expect(encoded, isNot(contains('tool-1')));
    expect(entries.single.operationId, startsWith('sha256:'));
    expect(encoded, isNot(contains('secret proposed content')));
    expect(encoded, isNot(contains('confirmation token')));
    expect(entries.single.toJson().keys, {
      'timestamp',
      'event',
      'level',
      'operationId',
      'conversationId',
      'toolCallId',
      'status',
      'errorType',
      'durationMs',
    });
  });

  test('free-form labels and identifiers cannot expose sensitive values', () {
    final entries = <AppLogEntry>[];
    final logger = AppLogger(sink: entries.add);

    logger.log(
      event: 'prompt: private content',
      operationId: 'nonce.encoded-private-memory.signature',
      fileName: '../private prompt.txt',
      status: 'Authorization: Bearer secret',
    );

    final encoded = entries.single.toString();
    expect(entries.single.event, 'redacted');
    expect(entries.single.status, 'redacted');
    expect(entries.single.toJson(), isNot(contains('fileName')));
    expect(encoded, isNot(contains('user.md')));
    expect(encoded, isNot(contains('private')));
    expect(encoded, isNot(contains('Bearer')));
    expect(encoded, isNot(contains('nonce')));
  });

  test('diagnostic ring retains only the newest 200 entries', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(diagnosticLogProvider.notifier);

    for (var index = 0; index < 205; index++) {
      notifier.add(
        AppLogEntry(
          timestamp: DateTime.utc(2026, 8, 17),
          event: 'event-$index',
          level: AppLogLevel.info,
        ),
      );
    }

    final entries = container.read(diagnosticLogProvider);
    expect(entries, hasLength(200));
    expect(entries.first.event, 'event-5');
    expect(entries.last.event, 'event-204');
  });
}
