import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'document_limits.dart';

enum DocumentWorkerOperation { pdfText, pdfOcr, imageOcr }

enum DocumentWorkerLanguage { eng, rus, engRus }

final class DocumentWorkerOptions {
  DocumentWorkerOptions({
    required this.operation,
    this.language = DocumentWorkerLanguage.engRus,
    this.firstPage = 1,
    this.pageCount = 1,
  }) {
    if (firstPage < 1 ||
        firstPage > 100 ||
        pageCount < 1 ||
        pageCount > 25 ||
        firstPage > 101 - pageCount ||
        (operation == DocumentWorkerOperation.imageOcr &&
            (firstPage != 1 || pageCount != 1))) {
      throw const DocumentException('invalid_document_worker_options');
    }
  }

  final DocumentWorkerOperation operation;
  final DocumentWorkerLanguage language;
  final int firstPage;
  final int pageCount;

  String get sha256Digest => sha256
      .convert(
        utf8.encode(
          'document-worker/1:${operation.index}:${language.index}:$firstPage:$pageCount',
        ),
      )
      .toString();

  void validate(DocumentLimits limits) {
    if (pageCount > limits.selectedPages ||
        firstPage > limits.pdfPages - pageCount + 1) {
      throw const DocumentException('document_page_limit');
    }
  }
}

final class DocumentWorkerRequest {
  DocumentWorkerRequest({
    required this.jobId,
    required Uint8List bytes,
    required this.sourceHash,
    required this.options,
    required this.limits,
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView() {
    options.validate(limits);
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(jobId) ||
        bytes.length > limits.sourceBytes ||
        sourceHash != sha256.convert(this.bytes).toString()) {
      throw const DocumentException('invalid_document_worker_request');
    }
  }

  final String jobId;
  final Uint8List bytes;
  final String sourceHash;
  final DocumentWorkerOptions options;
  final DocumentLimits limits;
}

enum DocumentWorkerCapability {
  isolatedProcess,
  offline,
  immutableInput,
  boundedOutput,
  nativeMemoryLimit,
  wallDeadline,
  confirmedTermination,
}

abstract interface class DocumentWorkerSupervisor {
  Set<DocumentWorkerCapability> get capabilities;

  // Returns ownership immediately, including while native startup is pending.
  // A throwing start must leave no worker or temporary resources behind.
  DocumentWorkerHandle start(DocumentWorkerRequest request);
}

abstract interface class DocumentWorkerHandle {
  String get jobId;

  // Chunks must be at most DocumentWorkerProtocol.maxChunkBytes. The native
  // broker must enforce that bound before allocating or delivering a chunk.
  Stream<List<int>> get output;

  // Idempotent; completes only after startup is cancelled and the process is
  // confirmed dead and reaped. Failure must throw, never claim termination.
  Future<void> terminateAndReap();

  // Called only after confirmed termination; releases the immutable snapshot.
  Future<void> cleanup();
}

final class DocumentWorkerCancellation {
  final Completer<void> _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }
}
