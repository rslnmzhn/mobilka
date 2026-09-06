import 'dart:async';
import 'dart:math';

import '../data/document_worker_protocol.dart';
import '../domain/document_extraction.dart';
import '../domain/document_limits.dart';
import '../domain/document_snapshot.dart';
import '../domain/document_worker_supervisor.dart';

final class NativeDocumentExtractor {
  NativeDocumentExtractor({required this.supervisor, DocumentLimits? limits})
    : limits = limits ?? DocumentLimits();

  final DocumentWorkerSupervisor supervisor;
  final DocumentLimits limits;
  bool _running = false;

  Future<NativeDocumentExtraction> extract(
    DocumentSnapshot snapshot, {
    required DocumentWorkerOptions options,
    DocumentWorkerCancellation? cancellation,
  }) async {
    if (_running) throw const DocumentException('document_worker_busy');
    if (!supervisor.capabilities.containsAll(DocumentWorkerCapability.values)) {
      throw const DocumentException('document_worker_unsupported');
    }
    if (cancellation?.isCancelled ?? false) {
      throw const DocumentException('document_worker_cancelled');
    }
    final random = Random.secure();
    final request = DocumentWorkerRequest(
      jobId: List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
      bytes: snapshot.bytes,
      sourceHash: snapshot.sha256Digest,
      options: options,
      limits: limits,
    );
    _running = true;
    DocumentWorkerHandle? handle;
    StreamSubscription<List<int>>? subscription;
    Timer? timer;
    var settled = false;
    final completion = Completer<List<DocumentWorkerPage>>();
    void fail(Object error, [StackTrace? stack]) {
      if (settled) return;
      settled = true;
      completion.completeError(error, stack);
    }

    final outcome = completion.future;
    try {
      final activeHandle = supervisor.start(request);
      handle = activeHandle;
      final decoder = DocumentWorkerResponseDecoder(request);
      timer = Timer(Duration(milliseconds: limits.wallMilliseconds), () {
        fail(const DocumentException('document_worker_timeout'));
      });
      cancellation?.whenCancelled.then((_) {
        fail(const DocumentException('document_worker_cancelled'));
      });
      // Defer stream delivery until the awaited future has its error handler.
      scheduleMicrotask(() {
        try {
          if (activeHandle.jobId != request.jobId) {
            throw const DocumentException('document_worker_job_mismatch');
          }
          subscription = activeHandle.output.listen(
            (chunk) {
              if (settled) return;
              try {
                decoder.add(chunk);
              } on Object catch (error, stack) {
                fail(error, stack);
              }
            },
            onError: (Object error, StackTrace stack) => fail(error, stack),
            onDone: () {
              if (settled) return;
              try {
                final pages = decoder.finish();
                if (cancellation?.isCancelled ?? false) {
                  throw const DocumentException('document_worker_cancelled');
                }
                settled = true;
                completion.complete(pages);
              } on Object catch (error, stack) {
                fail(error, stack);
              }
            },
          );
        } on Object catch (error, stack) {
          fail(error, stack);
        }
      });
      final pages = await outcome;
      return NativeDocumentExtraction(
        snapshot: snapshot,
        optionsHash: options.sha256Digest,
        pages: [
          for (final page in pages)
            NativeDocumentPage(page: page.page, ocr: page.ocr, text: page.text),
        ],
      );
    } finally {
      settled = true;
      timer?.cancel();
      var reaped = handle == null;
      try {
        if (handle != null) {
          // Never delete the snapshot while an unconfirmed worker may use it.
          await handle.terminateAndReap();
          reaped = true;
          try {
            await subscription?.cancel();
          } finally {
            await handle.cleanup();
          }
        }
      } finally {
        _running = !reaped;
      }
    }
  }
}
