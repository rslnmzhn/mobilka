import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/documents/application/native_document_extractor.dart';
import 'package:mobilka/features/documents/domain/document_limits.dart';
import 'package:mobilka/features/documents/domain/document_worker_supervisor.dart';

import 'document_worker_protocol_test.dart' show workerFrame;
import 'support/document_fixtures.dart';

final class FakeSupervisor implements DocumentWorkerSupervisor {
  @override
  Set<DocumentWorkerCapability> capabilities = DocumentWorkerCapability.values
      .toSet();
  late DocumentWorkerRequest request;
  late FakeHandle handle;
  int starts = 0;

  @override
  DocumentWorkerHandle start(DocumentWorkerRequest request) {
    starts++;
    this.request = request;
    return handle = FakeHandle(request.jobId);
  }
}

final class FakeHandle implements DocumentWorkerHandle {
  FakeHandle(this.jobId);
  @override
  final String jobId;
  final controller = StreamController<List<int>>();
  final events = <String>[];
  Completer<void>? termination;
  bool terminationFails = false;

  @override
  Stream<List<int>> get output => controller.stream;

  @override
  Future<void> terminateAndReap() async {
    events.add('terminate');
    if (terminationFails) throw StateError('termination failed');
    await termination?.future;
    events.add('reaped');
  }

  @override
  Future<void> cleanup() async {
    events.add('cleanup');
    await controller.close();
  }
}

void main() {
  final options = DocumentWorkerOptions(
    operation: DocumentWorkerOperation.pdfText,
  );

  test('unsupported capabilities never start a worker', () async {
    final supervisor = FakeSupervisor()..capabilities = {};
    await expectLater(
      NativeDocumentExtractor(
        supervisor: supervisor,
      ).extract(documentSnapshot([1]), options: options),
      throwsA(isA<DocumentException>()),
    );
    expect(supervisor.starts, 0);
  });

  test(
    'success retains parent provenance and waits for reap and cleanup',
    () async {
      final supervisor = FakeSupervisor();
      final snapshot = documentSnapshot([1]);
      final result = NativeDocumentExtractor(
        supervisor: supervisor,
      ).extract(snapshot, options: options);
      supervisor.handle.controller.add(
        workerFrame(supervisor.request, text: 'ok'),
      );
      supervisor.handle.controller.add(
        workerFrame(supervisor.request, terminal: true, index: 1, offset: 2),
      );
      unawaited(supervisor.handle.controller.close());
      final extraction = await result;
      expect(identical(extraction.snapshot, snapshot), isTrue);
      expect(extraction.optionsHash, options.sha256Digest);
      expect(extraction.pages.single.text, 'ok');
      expect(supervisor.handle.events, ['terminate', 'reaped', 'cleanup']);
    },
  );

  test('hanging stream times out and is reaped', () async {
    final supervisor = FakeSupervisor();
    await expectLater(
      NativeDocumentExtractor(
        supervisor: supervisor,
        limits: DocumentLimits(wallMilliseconds: 10),
      ).extract(documentSnapshot([1]), options: options),
      throwsA(isA<DocumentException>()),
    );
    expect(supervisor.handle.events, ['terminate', 'reaped', 'cleanup']);
  });

  test(
    'cancel ignores late success and waits for confirmed termination',
    () async {
      final supervisor = FakeSupervisor();
      final cancel = DocumentWorkerCancellation();
      final result = NativeDocumentExtractor(
        supervisor: supervisor,
      ).extract(documentSnapshot([1]), options: options, cancellation: cancel);
      var completed = false;
      final assertion = expectLater(
        result,
        throwsA(isA<DocumentException>()),
      ).then((_) => completed = true);
      supervisor.handle.termination = Completer<void>();
      cancel.cancel();
      await Future<void>.delayed(Duration.zero);
      supervisor.handle.controller.add(workerFrame(supervisor.request));
      supervisor.handle.controller.add(
        workerFrame(supervisor.request, terminal: true, index: 1),
      );
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(supervisor.handle.events, ['terminate']);
      supervisor.handle.termination!.complete();
      await assertion;
      expect(supervisor.handle.events.last, 'cleanup');
    },
  );

  test(
    'partial output or malformed frames never become successful results',
    () async {
      for (final malformed in [false, true]) {
        final supervisor = FakeSupervisor();
        final result = NativeDocumentExtractor(
          supervisor: supervisor,
        ).extract(documentSnapshot([1]), options: options);
        final assertion = expectLater(
          result,
          throwsA(isA<DocumentException>()),
        );
        final frame = workerFrame(supervisor.request);
        if (malformed) frame[6] ^= 1;
        supervisor.handle.controller.add(frame);
        unawaited(supervisor.handle.controller.close());
        await assertion;
        expect(supervisor.handle.events.last, 'cleanup');
      }
    },
  );

  test('failed termination forbids cleanup and reuse', () async {
    final supervisor = FakeSupervisor();
    final extractor = NativeDocumentExtractor(supervisor: supervisor);
    final result = extractor.extract(documentSnapshot([1]), options: options);
    supervisor.handle.terminationFails = true;
    final assertion = expectLater(result, throwsStateError);
    unawaited(supervisor.handle.controller.close());
    await assertion;
    expect(supervisor.handle.events, ['terminate']);
    await expectLater(
      extractor.extract(documentSnapshot([1]), options: options),
      throwsA(isA<DocumentException>()),
    );
    expect(supervisor.starts, 1);
  });
}
