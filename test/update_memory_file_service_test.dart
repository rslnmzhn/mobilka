import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobilka/features/memory/application/update_memory_file_service.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/presentation/memory_screen.dart';
import 'package:synchronized/synchronized.dart';

void main() {
  late _FakeMemoryBoundary boundary;
  late UpdateMemoryFileService service;
  var token = 0;

  setUp(() {
    boundary = _FakeMemoryBoundary({
      'user_profile.md': '# User\nold\n',
      'project_context.md': '# Project\n',
      'system_instructions.md': '# Instructions\n',
      'memory_log.md': '# Memory Log\n',
    });
    service = UpdateMemoryFileService(
      boundary,
      MemoryMutationCoordinator(
        boundary,
        now: () => DateTime.utc(2026, 8, 12, 10, 30),
      ),
      tokenFactory: () => 'token-${token++}',
    );
  });

  test(
    'rejects traversal, arbitrary markdown, and audit log updates',
    () async {
      for (final name in ['../user_profile.md', 'other.md', 'memory_log.md']) {
        await expectLater(
          service.preparePreview(name, 'unsafe'),
          throwsFormatException,
        );
      }
    },
  );

  test('preview reads current content and does not write', () async {
    final preview = await service.preparePreview(
      'user_profile.md',
      '# User\nnew\n',
    );

    expect(preview.confirmationToken, 'token-0');
    expect(preview.version, hasLength(64));
    expect(preview.diff, contains('-old'));
    expect(preview.diff, contains('+new'));
    expect(boundary.files['user_profile.md'], '# User\nold\n');
    expect(boundary.writes, isEmpty);
  });

  test('applies only with matching token and version', () async {
    final preview = await service.preparePreview(
      'user_profile.md',
      '# User\nnew\n',
    );

    await expectLater(
      service.apply(
        confirmationToken: preview.confirmationToken,
        version: 'wrong-version',
      ),
      throwsA(isA<UnknownMemoryConfirmationException>()),
    );
    final result = await service.apply(
      confirmationToken: preview.confirmationToken,
      version: preview.version,
    );

    expect(boundary.files['user_profile.md'], '# User\nnew\n');
    expect(result.previousVersion, preview.version);
    expect(result.version, isNot(preview.version));
    await expectLater(
      service.apply(
        confirmationToken: preview.confirmationToken,
        version: preview.version,
      ),
      throwsA(isA<UnknownMemoryConfirmationException>()),
    );
  });

  test('rejects confirmation when authoritative content is stale', () async {
    final preview = await service.preparePreview(
      'user_profile.md',
      '# User\nnew\n',
    );
    boundary.files['user_profile.md'] = '# User\nchanged elsewhere\n';

    await expectLater(
      service.apply(
        confirmationToken: preview.confirmationToken,
        version: preview.version,
      ),
      throwsA(isA<StaleMemoryPreviewException>()),
    );
    expect(boundary.files['user_profile.md'], contains('changed elsewhere'));
    expect(boundary.files['memory_log.md'], '# Memory Log\n');
  });

  test('target write failure leaves content and audit unchanged', () async {
    final preview = await service.preparePreview(
      'user_profile.md',
      '# User\nnew\n',
    );
    boundary.failWritesTo.add('user_profile.md');

    await expectLater(
      service.apply(
        confirmationToken: preview.confirmationToken,
        version: preview.version,
      ),
      throwsA(isA<MemoryAuditException>()),
    );
    expect(boundary.files['user_profile.md'], '# User\nold\n');
    expect(boundary.files['memory_log.md'], contains('"status":"failed"'));
    expect(
      boundary.files['memory_log.md'],
      isNot(contains('"status":"committed"')),
    );
  });

  test('audit failure rolls back the target update', () async {
    final preview = await service.preparePreview(
      'user_profile.md',
      '# User\nnew\n',
    );
    boundary.failWriteNumber = 3;

    await expectLater(
      service.apply(
        confirmationToken: preview.confirmationToken,
        version: preview.version,
      ),
      throwsA(
        isA<MemoryAuditException>().having(
          (error) => error.rollbackSucceeded,
          'rollbackSucceeded',
          isTrue,
        ),
      ),
    );
    expect(boundary.files['user_profile.md'], '# User\nold\n');
    expect(boundary.files['memory_log.md'], contains('"status":"pending"'));
    boundary.failWriteNumber = null;
    await service.recover();
    expect(boundary.files['memory_log.md'], contains('"status":"failed"'));
  });

  test(
    'appends one structured audit entry without recursive updates',
    () async {
      final preview = await service.preparePreview(
        'project_context.md',
        '# Project\nupdated\n',
      );
      await service.apply(
        confirmationToken: preview.confirmationToken,
        version: preview.version,
      );

      expect(boundary.writes, [
        'memory_log.md',
        'project_context.md',
        'memory_log.md',
      ]);
      final logLines = boundary.files['memory_log.md']!.trim().split('\n');
      final entry = jsonDecode(logLines.last) as Map<String, dynamic>;
      expect(entry['event'], 'update_memory_file');
      expect(entry['status'], 'committed');
      expect(entry['fileName'], 'project_context.md');
      expect(entry['timestamp'], '2026-08-12T10:30:00.000Z');
      expect(entry['previousVersion'], preview.version);
      expect(entry['version'], isNot(preview.version));
    },
  );

  test('serializes concurrent confirmed writes', () async {
    final first = await service.preparePreview(
      'user_profile.md',
      '# User\nfirst\n',
    );
    final second = await service.preparePreview(
      'project_context.md',
      '# Project\nsecond\n',
    );
    boundary.writeDelay = const Duration(milliseconds: 5);

    await Future.wait([
      service.apply(
        confirmationToken: first.confirmationToken,
        version: first.version,
      ),
      service.apply(
        confirmationToken: second.confirmationToken,
        version: second.version,
      ),
    ]);

    expect(boundary.maximumConcurrentTransactions, 1);
  });

  test('shared owner serializes separate update services', () async {
    final otherService = UpdateMemoryFileService(
      boundary,
      MemoryMutationCoordinator(boundary),
      tokenFactory: () => 'other-token',
    );
    final first = await service.preparePreview(
      'user_profile.md',
      '# User\nfirst\n',
    );
    final second = await otherService.preparePreview(
      'project_context.md',
      '# Project\nsecond\n',
    );
    boundary.writeDelay = const Duration(milliseconds: 5);

    await Future.wait([
      service.apply(
        confirmationToken: first.confirmationToken,
        version: first.version,
      ),
      otherService.apply(
        confirmationToken: second.confirmationToken,
        version: second.version,
      ),
    ]);

    expect(boundary.maximumConcurrentTransactions, 1);
  });

  test(
    'stale race is checked inside the target and audit transaction',
    () async {
      final preview = await service.preparePreview(
        'user_profile.md',
        '# User\nnew\n',
      );
      await boundary.write('user_profile.md', '# User\nintervening\n');

      await expectLater(
        service.apply(
          confirmationToken: preview.confirmationToken,
          version: preview.version,
        ),
        throwsA(isA<StaleMemoryPreviewException>()),
      );
      expect(boundary.files['user_profile.md'], contains('intervening'));
    },
  );

  test('failed commit audit never overwrites an intervening edit', () async {
    final preview = await service.preparePreview(
      'user_profile.md',
      '# User\nnew\n',
    );
    boundary.failWriteNumber = 3;
    boundary.onFailedWrite = () {
      boundary.files['user_profile.md'] = '# User\nintervening\n';
    };

    await expectLater(
      service.apply(
        confirmationToken: preview.confirmationToken,
        version: preview.version,
      ),
      throwsA(
        isA<MemoryAuditException>().having(
          (error) => error.rollbackSucceeded,
          'rollbackSucceeded',
          isTrue,
        ),
      ),
    );
    expect(boundary.files['user_profile.md'], contains('intervening'));
    expect(
      boundary.files['memory_log.md'],
      isNot(contains('"status":"committed"')),
    );
  });

  test('partial committed audit write is recovered as success', () async {
    final preview = await service.preparePreview(
      'user_profile.md',
      '# User\nnew\n',
    );
    boundary.failAfterWriteNumber = 3;

    final result = await service.apply(
      confirmationToken: preview.confirmationToken,
      version: preview.version,
    );

    expect(result.version, isNot(preview.version));
    expect(boundary.files['user_profile.md'], '# User\nnew\n');
    expect(boundary.files['memory_log.md'], contains('"status":"committed"'));
    expect(
      boundary.files['memory_log.md'],
      isNot(contains('"status":"failed"')),
    );
  });

  test(
    'production update_memory_file provider executes confirmed update',
    () async {
      final container = ProviderContainer(
        overrides: [updateMemoryFileProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      final execution = container.read(updateMemoryFileProvider)!;
      final preview = await execution.preparePreview(
        'system_instructions.md',
        '# Instructions\nBe concise.\n',
      );

      await execution.apply(
        confirmationToken: preview.confirmationToken,
        version: preview.version,
      );

      expect(updateMemoryFileProvider.name, 'update_memory_file');
      expect(boundary.files['system_instructions.md'], contains('Be concise.'));
    },
  );

  testWidgets('preview displays and confirms the exact token and version', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryUpdateSheet(
            fileName: 'user_profile.md',
            service: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('memory-update-content')),
      '# User\nconfirmed\n',
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    final tokenText = tester.widget<SelectableText>(
      find.byKey(const Key('memory-update-token')),
    );
    final versionText = tester.widget<SelectableText>(
      find.byKey(const Key('memory-update-version')),
    );
    expect(tokenText.data, contains(RegExp(r'token-\d+')));
    expect(versionText.data, contains(RegExp(r'[a-f0-9]{64}')));
    expect(find.byKey(const Key('memory-update-diff')), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-update-confirm')));
    await tester.pumpAndSettle();
    expect(boundary.files['user_profile.md'], '# User\nconfirmed\n');
  });
}

class _FakeMemoryBoundary implements MemoryFileBoundary {
  _FakeMemoryBoundary(this.files);

  final Map<String, String> files;
  final List<String> writes = [];
  final Set<String> failWritesTo = {};
  Duration writeDelay = Duration.zero;
  final Lock _lock = Lock();
  int? failWriteNumber;
  int? failAfterWriteNumber;
  void Function()? onFailedWrite;
  int _writeNumber = 0;
  int _concurrentTransactions = 0;
  int maximumConcurrentTransactions = 0;
  int _concurrentWrites = 0;
  int maximumConcurrentWrites = 0;

  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) => _lock.synchronized(() async {
    _concurrentTransactions++;
    maximumConcurrentTransactions =
        _concurrentTransactions > maximumConcurrentTransactions
        ? _concurrentTransactions
        : maximumConcurrentTransactions;
    try {
      return await action(_FakeMemoryTransaction(this));
    } finally {
      _concurrentTransactions--;
    }
  });

  @override
  Future<String> read(String fileName) async {
    final content = files[fileName];
    if (content == null) throw StateError('Missing $fileName');
    return content;
  }

  @override
  Future<void> write(String fileName, String content) async {
    _writeNumber++;
    if (failWritesTo.contains(fileName) || failWriteNumber == _writeNumber) {
      onFailedWrite?.call();
      throw StateError('Failed $fileName');
    }
    _concurrentWrites++;
    maximumConcurrentWrites = _concurrentWrites > maximumConcurrentWrites
        ? _concurrentWrites
        : maximumConcurrentWrites;
    try {
      if (writeDelay > Duration.zero) await Future<void>.delayed(writeDelay);
      files[fileName] = content;
      writes.add(fileName);
      if (failAfterWriteNumber == _writeNumber) {
        throw StateError('Failed after writing $fileName');
      }
    } finally {
      _concurrentWrites--;
    }
  }
}

class _FakeMemoryTransaction implements MemoryFileTransaction {
  const _FakeMemoryTransaction(this.boundary);

  final _FakeMemoryBoundary boundary;

  @override
  Future<String> read(String fileName) => boundary.read(fileName);

  @override
  Future<void> write(String fileName, String content) =>
      boundary.write(fileName, content);
}
