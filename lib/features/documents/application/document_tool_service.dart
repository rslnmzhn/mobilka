import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/document_extraction.dart';
import '../domain/document_limits.dart';
import '../domain/document_snapshot.dart';
import '../domain/document_tool_request.dart';
import '../domain/document_worker_supervisor.dart';
import 'local_document_extractor.dart';
import 'native_document_extractor.dart';

sealed class LocalDocumentToolResult {
  const LocalDocumentToolResult();

  DocumentSnapshot get snapshot;
  String get optionsIdentity;
  String get outputDigest;
}

final class ExtractedDocumentToolResult extends LocalDocumentToolResult {
  const ExtractedDocumentToolResult(this.extraction);

  final DocumentExtraction extraction;
  @override
  DocumentSnapshot get snapshot => extraction.snapshot;
  @override
  String get optionsIdentity => extraction.optionsIdentity;
  @override
  String get outputDigest => extraction.outputDigest;
}

final class NativeDocumentToolResult extends LocalDocumentToolResult {
  NativeDocumentToolResult(this.extraction)
    : outputDigest = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                'native-document-tool/1',
                extraction.snapshot.sha256Digest,
                extraction.optionsHash,
                extraction.pages
                    .map((page) => [page.page, page.ocr, page.text])
                    .toList(),
              ]),
            ),
          )
          .toString();

  final NativeDocumentExtraction extraction;
  @override
  DocumentSnapshot get snapshot => extraction.snapshot;
  @override
  String get optionsIdentity => extraction.optionsHash;
  @override
  final String outputDigest;
}

final class DocumentToolService {
  DocumentToolService({
    LocalDocumentExtractor? localExtractor,
    this.nativeExtractor,
    Set<DocumentWorkerOperation> readyNativeOperations = const {},
  }) : localExtractor = localExtractor ?? LocalDocumentExtractor(),
       readyNativeOperations = Set.unmodifiable(readyNativeOperations);

  final LocalDocumentExtractor localExtractor;
  final NativeDocumentExtractor? nativeExtractor;
  final Set<DocumentWorkerOperation> readyNativeOperations;

  bool supportsNative(DocumentWorkerOperation operation) {
    final extractor = nativeExtractor;
    return readyNativeOperations.contains(operation) &&
        extractor != null &&
        extractor.supervisor.capabilities.containsAll(
          DocumentWorkerCapability.values,
        );
  }

  Future<LocalDocumentToolResult> execute(
    DocumentToolRequest request, {
    required DocumentSnapshot snapshot,
    DocumentWorkerCancellation? cancellation,
  }) async {
    request.validateSnapshot(snapshot);
    if (cancellation?.isCancelled ?? false) {
      throw const DocumentException('document_worker_cancelled');
    }
    final options = request.nativeOptions;
    if (options == null) {
      return ExtractedDocumentToolResult(localExtractor.extract(snapshot));
    }
    if (!supportsNative(options.operation)) {
      throw DocumentException(
        request.operation == DocumentToolOperation.ocr
            ? 'document_ocr_unavailable'
            : 'document_pdf_unavailable',
      );
    }
    final extraction = await nativeExtractor!.extract(
      snapshot,
      options: options,
      cancellation: cancellation,
    );
    return NativeDocumentToolResult(extraction);
  }
}
