import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobilka/features/memory/application/update_memory_file_service.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/presentation/memory_screen.dart';
import 'package:synchronized/synchronized.dart';
import 'support/memory_delete_mixins.dart';

Future<void> applyPreview(
  UpdateMemoryFileService svc,
  MemoryUpdatePreview preview,
) async {
  await svc.apply(
    fileName: preview.fileName,
    proposedContent: preview.proposedContent,
    diff: preview.diff,
    createdAt: preview.createdAt,
    confirmationToken: preview.confirmationToken,
    version: preview.version,
  );
}

void main() {
  late _FakeMemoryBoundary boundary;
  late UpdateMemoryFileService service;
  var token = 0;

  setUp(() {
    token = 0;
    boundary = _FakeMemoryBoundary({
      'user.md': '# User\nold\n',

      'soul.md': '# Instructions\n',
      'memory.md': '# Memory Log\n',
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
      // soul.md is owner-editable via the UI path; arbitrary names rejected.
      for (final name in ['../user.md', 'other.md']) {
        await expectLater(
          service.preparePreview(name, 'unsafe'),
          throwsFormatException,
        );
      }
      final soulPreview = await service.preparePreview('soul.md', 'unsafe');
      expect(soulPreview.fileName, 'soul.md');
    },
  );

  test('preview reads current content and does not write', () async {
    final preview = await service.preparePreview('user.md', '# User\nnew\n');

    expect(preview.confirmationToken, 'token-0');
    expect(preview.version, hasLength(64));
    expect(preview.diff, contains('-old'));
    expect(preview.diff, contains('+new'));
    expect(boundary.files['user.md'], '# User\nold\n');
    expect(boundary.writes, isEmpty);
  });

  test('previews and confirms creation of a missing approved file', () async {
    boundary.files.remove('user.md');

    final preview = await service.preparePreview(
      'user.md',
      '# Project\ncreated\n',
    );

    expect(preview.isCreate, isTrue);
    expect(preview.version, UpdateMemoryFileService.missingVersion);
    expect(boundary.writes, isEmpty);

    await service.apply(
      fileName: preview.fileName,
      proposedContent: preview.proposedContent,
      diff: preview.diff,
      createdAt: preview.createdAt,
      confirmationToken: preview.confirmationToken,
      version: preview.version,
    );

    expect(boundary.files['user.md'], '# Project\ncreated\n');
  });

  test('applies only with matching token and version', () async {
    final preview = await service.preparePreview('user.md', '# User\nnew\n');

    await expectLater(
      service.apply(
        fileName: preview.fileName,
        proposedContent: preview.proposedContent,
        diff: preview.diff,
        createdAt: preview.createdAt,
        confirmationToken: preview.confirmationToken,
        version: 'wrong-version',
      ),
      throwsA(isA<UnknownMemoryConfirmationException>()),
    );
    final result = await service.apply(
      fileName: preview.fileName,
      proposedContent: preview.proposedContent,
      diff: preview.diff,
      createdAt: preview.createdAt,
      confirmationToken: preview.confirmationToken,
      version: preview.version,
    );

    expect(boundary.files['user.md'], '# User\nnew\n');
    expect(result.previousVersion, preview.version);
    expect(result.version, isNot(preview.version));
    final replay = await service.applyPersisted(
      fileName: preview.fileName,
      proposedContent: preview.proposedContent,
      diff: preview.diff,
      confirmationToken: preview.confirmationToken,
      version: preview.version,
      createdAt: preview.createdAt,
    );
    expect(replay.version, result.version);
  });

  test('rejects confirmation when authoritative content is stale', () async {
    final preview = await service.preparePreview('user.md', '# User\nnew\n');
    boundary.files['user.md'] = '# User\nchanged elsewhere\n';

    await expectLater(
      service.apply(
        fileName: preview.fileName,
        proposedContent: preview.proposedContent,
        diff: preview.diff,
        createdAt: preview.createdAt,
        confirmationToken: preview.confirmationToken,
        version: preview.version,
      ),
      throwsA(isA<StaleMemoryPreviewException>()),
    );
    expect(boundary.files['user.md'], contains('changed elsewhere'));
    expect(boundary.files['memory.md'], '# Memory Log\n');
  });

  test('target write failure leaves content and audit unchanged', () async {
    final preview = await service.preparePreview('user.md', '# User\nnew\n');
    boundary.failWritesTo.add('user.md');

    await expectLater(
      service.apply(
        fileName: preview.fileName,
        proposedContent: preview.proposedContent,
        diff: preview.diff,
        createdAt: preview.createdAt,
        confirmationToken: preview.confirmationToken,
        version: preview.version,
      ),
      throwsA(isA<MemoryAuditException>()),
    );
    expect(boundary.files['user.md'], '# User\nold\n');
    expect(boundary.files['memory.md'], contains('"status":"failed"'));
    expect(
      boundary.files['memory.md'],
      isNot(contains('"status":"committed"')),
    );
  });

  test('audit failure after target apply is finalized as committed', () async {
    final preview = await service.preparePreview('user.md', '# User\nnew\n');
    boundary.failWriteNumber = 2;

    await service.apply(
      fileName: preview.fileName,
      proposedContent: preview.proposedContent,
      diff: preview.diff,
      createdAt: preview.createdAt,
      confirmationToken: preview.confirmationToken,
      version: preview.version,
    );
    expect(boundary.files['user.md'], '# User\nnew\n');
    expect(boundary.files['memory.md'], contains('"status":"committed"'));
  });

  test(
    'appends one structured audit entry without recursive updates',
    () async {
      final preview = await service.preparePreview(
        'user.md',
        '# Project\nupdated\n',
      );
      await service.apply(
        fileName: preview.fileName,
        proposedContent: preview.proposedContent,
        diff: preview.diff,
        createdAt: preview.createdAt,
        confirmationToken: preview.confirmationToken,
        version: preview.version,
      );

      expect(boundary.writes, ['user.md', 'memory.md']);
      final logLines = boundary.files['memory.md']!.trim().split('\n');
      final entry = jsonDecode(logLines.last) as Map<String, dynamic>;
      expect(entry['event'], 'update_memory_file');
      expect(entry['status'], 'committed');
      expect(entry['fileName'], 'user.md');
      expect(entry['timestamp'], '2026-08-12T10:30:00.000Z');
      expect(entry['previousVersion'], preview.version);
      expect(entry['version'], isNot(preview.version));
      expect(entry, isNot(contains('previous')));
      expect(boundary.files['memory.md'], isNot(contains('I29sZAo=')));
      expect(
        boundary.files['memory.md'],
        isNot(contains(preview.confirmationToken)),
      );
    },
  );

  test('serializes concurrent confirmed writes', () async {
    final first = await service.preparePreview('user.md', '# User\nfirst\n');
    final second = await service.preparePreview(
      'user.md',
      '# Project\nsecond\n',
    );
    boundary.writeDelay = const Duration(milliseconds: 5);

    await Future.wait([
      applyPreview(service, first),
      // The loser of the race is detected as stale inside the transaction.
      () async {
        try {
          await applyPreview(service, second);
        } on StaleMemoryPreviewException {
          // expected loser of the race
        }
      }(),
    ]);

    expect(boundary.maximumConcurrentTransactions, 1);
  });

  test('shared owner serializes separate update services', () async {
    final otherService = UpdateMemoryFileService(
      boundary,
      MemoryMutationCoordinator(boundary),
      tokenFactory: () => 'other-token',
    );
    final first = await service.preparePreview('user.md', '# User\nfirst\n');
    final second = await otherService.preparePreview(
      'user.md',
      '# Project\nsecond\n',
    );
    boundary.writeDelay = const Duration(milliseconds: 5);

    await Future.wait([
      applyPreview(service, first),
      // The loser of the race is detected as stale inside the transaction.
      () async {
        try {
          await applyPreview(otherService, second);
        } on StaleMemoryPreviewException {
          // expected loser of the race
        }
      }(),
    ]);

    expect(boundary.maximumConcurrentTransactions, 1);
  });

  test(
    'stale race is checked inside the target and audit transaction',
    () async {
      final preview = await service.preparePreview('user.md', '# User\nnew\n');
      await boundary.write('user.md', '# User\nintervening\n');

      await expectLater(
        service.apply(
          fileName: preview.fileName,
          proposedContent: preview.proposedContent,
          diff: preview.diff,
          createdAt: preview.createdAt,
          confirmationToken: preview.confirmationToken,
          version: preview.version,
        ),
        throwsA(isA<StaleMemoryPreviewException>()),
      );
      expect(boundary.files['user.md'], contains('intervening'));
    },
  );

  test('partial target failure never overwrites an intervening edit', () async {
    final preview = await service.preparePreview('user.md', '# User\nnew\n');
    boundary.failWriteNumber = 1;
    boundary.onFailedWrite = () {
      boundary.files['user.md'] = '# User\nintervening\n';
    };

    await expectLater(
      service.apply(
        fileName: preview.fileName,
        proposedContent: preview.proposedContent,
        diff: preview.diff,
        createdAt: preview.createdAt,
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
    expect(boundary.files['user.md'], contains('intervening'));
    expect(
      boundary.files['memory.md'],
      isNot(contains('"status":"committed"')),
    );
  });

  test('audit mirror failure after durable apply is finalized once', () async {
    final preview = await service.preparePreview('user.md', '# User\nnew\n');
    boundary.failAfterWriteNumber = 2;

    await service.apply(
      fileName: preview.fileName,
      proposedContent: preview.proposedContent,
      diff: preview.diff,
      createdAt: preview.createdAt,
      confirmationToken: preview.confirmationToken,
      version: preview.version,
    );

    expect(boundary.files['user.md'], '# User\nnew\n');
    expect(boundary.files['memory.md'], contains('"status":"committed"'));
    expect(
      '"status":"committed"'.allMatches(boundary.files['memory.md']!),
      hasLength(1),
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
        'soul.md',
        '# Instructions\nBe concise.\n',
      );

      await execution.apply(
        fileName: preview.fileName,
        proposedContent: preview.proposedContent,
        diff: preview.diff,
        createdAt: preview.createdAt,
        confirmationToken: preview.confirmationToken,
        version: preview.version,
      );

      expect(updateMemoryFileProvider.name, 'update_memory_file');
      expect(boundary.files['soul.md'], contains('Be concise.'));
    },
  );

  test('persisted proposal confirmation is idempotent after apply', () async {
    final preview = await service.preparePreview('user.md', '# User\nnew\n');

    final first = await service.applyPersisted(
      fileName: preview.fileName,
      proposedContent: '# User\nnew\n',
      diff: preview.diff,
      confirmationToken: preview.confirmationToken,
      version: preview.version,
      createdAt: preview.createdAt,
    );
    final second = await service.applyPersisted(
      fileName: preview.fileName,
      proposedContent: '# User\nnew\n',
      diff: preview.diff,
      confirmationToken: preview.confirmationToken,
      version: preview.version,
      createdAt: preview.createdAt,
    );

    expect(second.version, first.version);
    expect(
      '"status":"committed"'.allMatches(boundary.files['memory.md']!),
      hasLength(1),
    );
  });

  test(
    'preview survives service replacement without retained proposal state',
    () async {
      final preview = await service.preparePreview('user.md', '# User\nnew\n');
      final replacement = UpdateMemoryFileService(
        boundary,
        MemoryMutationCoordinator(boundary),
        proposals: service.proposalAuthority,
      );

      await replacement.applyPersisted(
        fileName: preview.fileName,
        proposedContent: preview.proposedContent,
        diff: preview.diff,
        confirmationToken: preview.confirmationToken,
        version: preview.version,
        createdAt: preview.createdAt,
      );

      expect(boundary.files['user.md'], '# User\nnew\n');
    },
  );

  testWidgets('preview hides token and confirms the exact version', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryUpdateSheet(fileName: 'user.md', service: service),
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

    final versionText = tester.widget<SelectableText>(
      find.byKey(const Key('memory-update-version')),
    );
    expect(find.byKey(const Key('memory-update-token')), findsNothing);
    expect(versionText.data, contains(RegExp(r'[a-f0-9]{64}')));
    expect(find.byKey(const Key('memory-update-diff')), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-update-confirm')));
    await tester.pumpAndSettle();
    expect(boundary.files['user.md'], '# User\nconfirmed\n');
  });
}

class _FakeMemoryBoundary
    with MemoryBoundaryDelete
    implements MemoryFileBoundary {
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

class _FakeMemoryTransaction
    implements MemoryFileTransaction, MissingAwareMemoryFileTransaction {
  const _FakeMemoryTransaction(this.boundary);

  final _FakeMemoryBoundary boundary;

  @override
  Future<String> read(String fileName) => boundary.read(fileName);

  @override
  Future<String?> readIfExists(String fileName) async =>
      boundary.files[fileName];

  @override
  Future<void> write(String fileName, String content) =>
      boundary.write(fileName, content);
}
