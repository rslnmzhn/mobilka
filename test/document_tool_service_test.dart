import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/documents/application/document_tool_service.dart';
import 'package:mobilka/features/documents/application/native_document_extractor.dart';
import 'package:mobilka/features/documents/domain/document_extraction.dart';
import 'package:mobilka/features/documents/domain/document_limits.dart';
import 'package:mobilka/features/documents/domain/document_snapshot.dart';
import 'package:mobilka/features/documents/domain/document_tool_request.dart';
import 'package:mobilka/features/documents/domain/document_worker_supervisor.dart';

import 'support/document_fixtures.dart';

final class _UnavailableProcessor implements DocumentWorkerSupervisor {
  _UnavailableProcessor(this.capabilities);

  @override
  final Set<DocumentWorkerCapability> capabilities;
  int starts = 0;

  @override
  DocumentWorkerHandle start(DocumentWorkerRequest request) {
    starts++;
    throw const DocumentException('test_native_processor_unavailable');
  }
}

DocumentToolRequest _request(
  DocumentSnapshot snapshot, {
  String tool = 'extract_document',
  String? format,
}) => DocumentToolRequest.parse(
  tool,
  jsonEncode({
    'path': snapshot.sourcePath.value,
    'source_sha256': snapshot.sha256Digest,
    'format': format ?? snapshot.sourcePath.components.last.split('.').last,
  }),
);

Matcher _code(String code) =>
    throwsA(isA<DocumentException>().having((e) => e.code, 'code', code));

void main() {
  test(
    'real CSV, DOCX and XLSX extraction preserves owned local payload',
    () async {
      final service = DocumentToolService();
      final inputs = <String, List<int>>{
        'csv': utf8.encode('hello,Привет'),
        'docx': simpleDocx('<w:p><w:r><w:t>Привет</w:t></w:r></w:p>'),
        'xlsx': simpleXlsx(
          '<c r="A1" t="inlineStr"><is><t>Привет</t></is></c>',
        ),
      };
      for (final entry in inputs.entries) {
        final snapshot = documentSnapshot(
          entry.value,
          path: 'input.${entry.key}',
        );
        final result =
            (await service.execute(_request(snapshot), snapshot: snapshot))
                as ExtractedDocumentToolResult;
        expect(result.snapshot, same(snapshot));
        expect(result.extraction.format.name, entry.key);
        expect(
          result.extraction.fragments.map((f) => f.text).join(),
          contains('Привет'),
        );
        expect(result.optionsIdentity, result.extraction.optionsIdentity);
        expect(result.outputDigest, result.extraction.outputDigest);
        expect(result.outputDigest, matches(r'^[0-9a-f]{64}$'));
        expect(result.extraction.fragments.first.part, isNotEmpty);
        final repeat = await service.execute(
          _request(snapshot),
          snapshot: snapshot,
        );
        expect(repeat.outputDigest, result.outputDigest);
      }
    },
  );

  test('path and hash must both match before any worker invocation', () async {
    final supervisor = _UnavailableProcessor(
      DocumentWorkerCapability.values.toSet(),
    );
    final service = DocumentToolService(
      nativeExtractor: NativeDocumentExtractor(supervisor: supervisor),
      readyNativeOperations: DocumentWorkerOperation.values.toSet(),
    );
    final snapshot = documentSnapshot([1], path: 'input.pdf');
    for (final other in [
      documentSnapshot([1], path: 'other.pdf'),
      documentSnapshot([2], path: 'input.pdf'),
    ]) {
      await expectLater(
        service.execute(_request(other), snapshot: snapshot),
        _code('document_snapshot_mismatch'),
      );
    }
    expect(supervisor.starts, 0);
  });

  test(
    'native readiness defaults empty, independent of safety flags',
    () async {
      final supervisor = _UnavailableProcessor(
        DocumentWorkerCapability.values.toSet(),
      );
      final service = DocumentToolService(
        nativeExtractor: NativeDocumentExtractor(supervisor: supervisor),
      );
      for (final entry in [
        ('extract_document', 'pdf'),
        ('ocr_document', 'png'),
      ]) {
        final snapshot = documentSnapshot([1], path: 'input.${entry.$2}');
        await expectLater(
          service.execute(
            _request(snapshot, tool: entry.$1),
            snapshot: snapshot,
          ),
          _code(
            entry.$1 == 'ocr_document'
                ? 'document_ocr_unavailable'
                : 'document_pdf_unavailable',
          ),
        );
      }
      expect(supervisor.starts, 0);
    },
  );

  test(
    'every mandatory safety capability fails closed without invocation',
    () async {
      for (final missing in DocumentWorkerCapability.values) {
        final supervisor = _UnavailableProcessor(
          DocumentWorkerCapability.values.toSet()..remove(missing),
        );
        final service = DocumentToolService(
          nativeExtractor: NativeDocumentExtractor(supervisor: supervisor),
          readyNativeOperations: DocumentWorkerOperation.values.toSet(),
        );
        for (final format in ['png', 'jpeg', 'pdf']) {
          final snapshot = documentSnapshot([1], path: 'input.$format');
          await expectLater(
            service.execute(
              _request(snapshot, tool: 'ocr_document'),
              snapshot: snapshot,
            ),
            _code('document_ocr_unavailable'),
          );
        }
        expect(supervisor.starts, 0);
      }
    },
  );

  test(
    'readiness is immutable, operation-specific and probing is read-only',
    () async {
      final ready = {DocumentWorkerOperation.pdfText};
      final supervisor = _UnavailableProcessor(
        DocumentWorkerCapability.values.toSet(),
      );
      final service = DocumentToolService(
        nativeExtractor: NativeDocumentExtractor(supervisor: supervisor),
        readyNativeOperations: ready,
      );
      ready.clear();
      expect(service.supportsNative(DocumentWorkerOperation.pdfText), true);
      expect(service.supportsNative(DocumentWorkerOperation.pdfOcr), false);
      expect(service.supportsNative(DocumentWorkerOperation.imageOcr), false);
      expect(
        () => service.readyNativeOperations.clear(),
        throwsUnsupportedError,
      );
      expect(supervisor.starts, 0);
      final snapshot = documentSnapshot([1], path: 'input.pdf');
      await expectLater(
        service.execute(_request(snapshot), snapshot: snapshot),
        _code('test_native_processor_unavailable'),
      );
      expect(supervisor.starts, 1);
    },
  );

  test('normal image extraction rejects without silently invoking OCR', () {
    final supervisor = _UnavailableProcessor(
      DocumentWorkerCapability.values.toSet(),
    );
    final service = DocumentToolService(
      nativeExtractor: NativeDocumentExtractor(supervisor: supervisor),
      readyNativeOperations: DocumentWorkerOperation.values.toSet(),
    );
    expect(service.supportsNative(DocumentWorkerOperation.imageOcr), true);
    for (final format in ['png', 'jpeg']) {
      final snapshot = documentSnapshot([1], path: 'input.$format');
      expect(() => _request(snapshot), _code('unsupported_document_type'));
    }
    expect(supervisor.starts, 0);
  });

  test(
    'native wrapper retains owner and hashes options and page provenance',
    () {
      final snapshot = documentSnapshot([1], path: 'input.pdf');
      NativeDocumentExtraction extraction(
        int page,
        bool ocr,
        String text,
        String options,
      ) => NativeDocumentExtraction(
        snapshot: snapshot,
        optionsHash: options,
        pages: [NativeDocumentPage(page: page, ocr: ocr, text: text)],
      );
      final payload = extraction(
        1,
        true,
        'fixture, not processor output',
        'options',
      );
      final result = NativeDocumentToolResult(payload);
      expect(result.extraction, same(payload));
      expect(result.snapshot, same(snapshot));
      expect(result.optionsIdentity, payload.optionsHash);
      expect(
        result.outputDigest,
        NativeDocumentToolResult(payload).outputDigest,
      );
      for (final other in [
        extraction(2, true, 'fixture, not processor output', 'options'),
        extraction(1, false, 'fixture, not processor output', 'options'),
        extraction(1, true, 'different', 'options'),
        extraction(1, true, 'fixture, not processor output', 'other'),
      ]) {
        expect(
          NativeDocumentToolResult(other).outputDigest,
          isNot(result.outputDigest),
        );
      }
    },
  );

  test('pre-cancelled requests do not extract', () async {
    final snapshot = documentSnapshot(utf8.encode('hello'));
    final cancellation = DocumentWorkerCancellation()..cancel();
    await expectLater(
      DocumentToolService().execute(
        _request(snapshot),
        snapshot: snapshot,
        cancellation: cancellation,
      ),
      _code('document_worker_cancelled'),
    );
  });
}
