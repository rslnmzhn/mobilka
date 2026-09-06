import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/documents/data/document_worker_protocol.dart';
import 'package:mobilka/features/documents/domain/document_limits.dart';
import 'package:mobilka/features/documents/domain/document_worker_supervisor.dart';

import 'support/document_fixtures.dart';

DocumentWorkerRequest workerRequest({
  DocumentLimits? limits,
  DocumentWorkerOperation operation = DocumentWorkerOperation.pdfText,
  int pageCount = 1,
}) {
  final snapshot = documentSnapshot([1, 2, 3]);
  return DocumentWorkerRequest(
    jobId: '0123456789abcdef0123456789abcdef',
    bytes: snapshot.bytes,
    sourceHash: snapshot.sha256Digest,
    options: DocumentWorkerOptions(operation: operation, pageCount: pageCount),
    limits: limits ?? DocumentLimits(),
  );
}

List<int> workerFrame(
  DocumentWorkerRequest request, {
  bool terminal = false,
  int index = 0,
  int page = 1,
  int offset = 0,
  int status = 0,
  int width = 0,
  int height = 0,
  String text = '',
}) {
  final content = utf8.encode(text);
  final frame = Uint8List(51 + content.length);
  final data = ByteData.sublistView(frame);
  data.setUint32(0, frame.length - 4);
  frame[4] = 1;
  frame[5] = terminal ? 1 : 0;
  for (var i = 0; i < 16; i++) {
    frame[6 + i] = int.parse(
      request.jobId.substring(i * 2, i * 2 + 2),
      radix: 16,
    );
  }
  data.setUint32(22, index);
  data.setUint32(26, terminal ? 0 : page);
  data.setUint32(30, offset);
  frame[34] = status;
  data.setUint32(39, width);
  data.setUint32(43, height);
  data.setUint32(47, content.length);
  frame.setRange(51, frame.length, content);
  return frame;
}

void main() {
  test(
    'request round trip retains hash, options and enforced limit contract',
    () {
      final request = workerRequest();
      final encoded = DocumentWorkerProtocol.encodeRequest(request);
      final decoded = DocumentWorkerProtocol.decodeRequest(encoded);
      expect(decoded.sourceHash, request.sourceHash);
      expect(decoded.options.sha256Digest, request.options.sha256Digest);
      expect(decoded.limits.nativeMemoryBytes, 268435456);
      expect(decoded.limits.selectedPages, 25);
      expect(decoded.limits.pagePixels, 4000000);
      expect(decoded.limits.totalPixels, 20000000);
      expect(() => decoded.bytes[0] = 2, throwsUnsupportedError);
      for (final position in [3, 52, 53, 58, 104, encoded.length - 1]) {
        final corrupt = Uint8List.fromList(encoded);
        corrupt[position] = 255;
        expect(
          () => DocumentWorkerProtocol.decodeRequest(corrupt),
          throwsA(isA<DocumentException>()),
        );
      }
    },
  );

  test(
    'split prefixes and UTF8 require a matching terminal and complete EOF',
    () {
      final request = workerRequest();
      final decoder = DocumentWorkerResponseDecoder(request);
      final text = 'Привет';
      for (final byte in workerFrame(request, text: text)) {
        decoder.add([byte]);
      }
      expect(decoder.finish, throwsA(isA<DocumentException>()));
      decoder.add(
        workerFrame(
          request,
          terminal: true,
          index: 1,
          offset: utf8.encode(text).length,
        ),
      );
      expect(decoder.finish().single.text, text);
      expect(() => decoder.add([0]), throwsA(isA<DocumentException>()));
      expect(decoder.finish, throwsA(isA<DocumentException>()));
    },
  );

  test(
    'unknown fields, cross-job, index, offset and truncation fail closed',
    () {
      final request = workerRequest();
      for (final position in [4, 5, 6, 25, 29, 33, 34, 38, 50]) {
        final frame = workerFrame(request);
        frame[position] = 255;
        final decoder = DocumentWorkerResponseDecoder(request);
        expect(() => decoder.add(frame), throwsA(isA<DocumentException>()));
      }
    },
  );

  test('record bounds are checked before text decoding or body allocation', () {
    final request = workerRequest(limits: DocumentLimits(pageOutputBytes: 2));
    final decoder = DocumentWorkerResponseDecoder(request);
    expect(() => decoder.add([0, 4, 0, 48]), throwsA(isA<DocumentException>()));
    expect(
      () => DocumentWorkerResponseDecoder(
        request,
      ).add(List.filled(DocumentWorkerProtocol.maxChunkBytes + 1, 0)),
      throwsA(isA<DocumentException>()),
    );
    final invalidUtf8 = workerFrame(request, text: 'a');
    invalidUtf8[51] = 255;
    expect(
      () => DocumentWorkerResponseDecoder(request).add(invalidUtf8),
      throwsFormatException,
    );
  });

  test('checked raster arithmetic and aggregate pixel caps', () {
    final limits = DocumentLimits(totalPixels: 4);
    expect(
      () => limits.checkedRasterPixels(0xffffffff, 0xffffffff),
      throwsA(isA<DocumentException>()),
    );
    expect(
      () => limits.checkedRasterPixels(4096, 4096),
      throwsA(isA<DocumentException>()),
    );
    final request = workerRequest(
      limits: limits,
      operation: DocumentWorkerOperation.pdfOcr,
      pageCount: 2,
    );
    final decoder = DocumentWorkerResponseDecoder(request);
    decoder.add(workerFrame(request, status: 1, width: 2, height: 2));
    expect(
      () => decoder.add(
        workerFrame(request, index: 1, page: 2, status: 1, width: 1, height: 1),
      ),
      throwsA(isA<DocumentException>()),
    );
    expect(
      () => DocumentLimits(selectedPages: 26),
      throwsA(isA<DocumentException>()),
    );
    expect(
      () => DocumentLimits(wallMilliseconds: 30001),
      throwsA(isA<DocumentException>()),
    );
    expect(
      () => DocumentLimits(nativeMemoryBytes: 268435457),
      throwsA(isA<DocumentException>()),
    );
  });
}
