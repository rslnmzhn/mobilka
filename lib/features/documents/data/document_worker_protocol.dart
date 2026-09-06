import 'dart:convert';
import 'dart:typed_data';

import '../domain/document_limits.dart';
import '../domain/document_worker_supervisor.dart';

final class DocumentWorkerPage {
  const DocumentWorkerPage({
    required this.page,
    required this.ocr,
    required this.text,
    required this.width,
    required this.height,
  });

  final int page;
  final bool ocr;
  final String text;
  final int width;
  final int height;
}

// All integers are unsigned, big-endian. No optional fields or trailing bytes.
// Request: magic/version, job(16), hash(32), operation/language, first/count,
// source length, ten limits, then source bytes. Paths never cross this boundary.
// Response frames: length(u32), version(u8), kind(u8), job(16), index(u32),
// page(u32), offset(u32), status(u8), truncated(u32), width/height(u32),
// textLength(u32), UTF-8 text. One complete page per frame, then terminal.
abstract final class DocumentWorkerProtocol {
  static const version = 1;
  static const maxChunkBytes = 65536;
  static const responseHeaderBytes = 47;
  static const requestHeaderBytes = 108;

  static Uint8List encodeRequest(DocumentWorkerRequest request) {
    final limits = request.limits;
    final result = Uint8List(requestHeaderBytes + request.bytes.length);
    final data = ByteData.sublistView(result);
    result.setRange(0, 4, [0x4d, 0x44, 0x57, version]);
    result.setRange(4, 20, _unhex(request.jobId));
    result.setRange(20, 52, _unhex(request.sourceHash));
    result[52] = request.options.operation.index;
    result[53] = request.options.language.index;
    data.setUint16(54, request.options.firstPage);
    data.setUint16(56, request.options.pageCount);
    data.setUint16(58, 0);
    final fields = [
      request.bytes.length,
      limits.sourceBytes,
      limits.pdfPages,
      limits.selectedPages,
      limits.rasterDimension,
      limits.pagePixels,
      limits.totalPixels,
      limits.pageOutputBytes,
      limits.outputBytes,
      limits.wallMilliseconds,
      limits.nativeMemoryBytes,
    ];
    for (var i = 0; i < fields.length; i++) {
      data.setUint32(60 + i * 4, fields[i]);
    }
    data.setUint32(104, 0);
    result.setRange(requestHeaderBytes, result.length, request.bytes);
    return result.asUnmodifiableView();
  }

  static DocumentWorkerRequest decodeRequest(Uint8List bytes) {
    if (bytes.length < requestHeaderBytes ||
        bytes.length > requestHeaderBytes + 10485760 ||
        bytes[0] != 0x4d ||
        bytes[1] != 0x44 ||
        bytes[2] != 0x57 ||
        bytes[3] != version) {
      throw const DocumentException('invalid_document_worker_protocol');
    }
    final data = ByteData.sublistView(bytes);
    int field(int index) => data.getUint32(60 + index * 4);
    if (bytes[52] >= DocumentWorkerOperation.values.length ||
        bytes[53] >= DocumentWorkerLanguage.values.length ||
        data.getUint16(58) != 0 ||
        data.getUint32(104) != 0 ||
        field(0) != bytes.length - requestHeaderBytes) {
      throw const DocumentException('invalid_document_worker_protocol');
    }
    return DocumentWorkerRequest(
      jobId: _hex(bytes.sublist(4, 20)),
      bytes: Uint8List.sublistView(bytes, requestHeaderBytes),
      sourceHash: _hex(bytes.sublist(20, 52)),
      options: DocumentWorkerOptions(
        operation: DocumentWorkerOperation.values[bytes[52]],
        language: DocumentWorkerLanguage.values[bytes[53]],
        firstPage: data.getUint16(54),
        pageCount: data.getUint16(56),
      ),
      limits: DocumentLimits(
        sourceBytes: field(1),
        pdfPages: field(2),
        selectedPages: field(3),
        rasterDimension: field(4),
        pagePixels: field(5),
        totalPixels: field(6),
        pageOutputBytes: field(7),
        outputBytes: field(8),
        wallMilliseconds: field(9),
        nativeMemoryBytes: field(10),
      ),
    );
  }

  static String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _unhex(String value) => [
    for (var i = 0; i < value.length; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16),
  ];
}

final class DocumentWorkerResponseDecoder {
  DocumentWorkerResponseDecoder(this.request);

  final DocumentWorkerRequest request;
  final List<DocumentWorkerPage> _pages = [];
  final Uint8List _prefix = Uint8List(4);
  int _prefixUsed = 0;
  Uint8List? _frame;
  int _frameUsed = 0;
  int _outputBytes = 0;
  int _pixels = 0;
  int _wireBytes = 0;
  bool _terminal = false;
  bool _failed = false;

  void add(List<int> chunk) {
    try {
      _add(chunk);
    } on Object {
      _failed = true;
      rethrow;
    }
  }

  void _add(List<int> chunk) {
    final limits = request.limits;
    final maxWire =
        limits.outputBytes +
        (request.options.pageCount + 1) *
            (4 + DocumentWorkerProtocol.responseHeaderBytes);
    if (_failed ||
        chunk.length > DocumentWorkerProtocol.maxChunkBytes ||
        chunk.length > maxWire - _wireBytes) {
      throw const DocumentException('document_worker_output_limit');
    }
    _wireBytes += chunk.length;
    for (final byte in chunk) {
      if (_terminal || byte < 0 || byte > 255) _invalid();
      if (_frame == null) {
        _prefix[_prefixUsed++] = byte;
        if (_prefixUsed == 4) {
          final length = ByteData.sublistView(_prefix).getUint32(0);
          if (length < DocumentWorkerProtocol.responseHeaderBytes ||
              length >
                  DocumentWorkerProtocol.responseHeaderBytes +
                      limits.pageOutputBytes ||
              length - DocumentWorkerProtocol.responseHeaderBytes >
                  limits.outputBytes - _outputBytes) {
            throw const DocumentException('document_worker_output_limit');
          }
          _frame = Uint8List(length);
          _frameUsed = 0;
          _prefixUsed = 0;
        }
      } else {
        _frame![_frameUsed++] = byte;
        if (_frameUsed == _frame!.length) {
          _consume(_frame!);
          _frame = null;
        }
      }
    }
  }

  void _consume(Uint8List frame) {
    final data = ByteData.sublistView(frame);
    final page = data.getUint32(22);
    final offset = data.getUint32(26);
    final status = frame[30];
    final truncated = data.getUint32(31);
    final width = data.getUint32(35);
    final height = data.getUint32(39);
    final textLength = data.getUint32(43);
    if (frame[0] != DocumentWorkerProtocol.version ||
        DocumentWorkerProtocol._hex(frame.sublist(2, 18)) != request.jobId ||
        data.getUint32(18) != _pages.length ||
        offset != _outputBytes ||
        truncated != 0 ||
        textLength != frame.length - 47) {
      _invalid();
    }
    if (frame[1] == 1) {
      if (status != 0 ||
          page != 0 ||
          width != 0 ||
          height != 0 ||
          textLength != 0 ||
          _pages.length != request.options.pageCount) {
        _invalid();
      }
      _terminal = true;
      return;
    }
    if (frame[1] != 0 ||
        _pages.length >= request.options.pageCount ||
        page != request.options.firstPage + _pages.length) {
      _invalid();
    }
    final ocr = request.options.operation != DocumentWorkerOperation.pdfText;
    if (status != (ocr ? 1 : 0)) _invalid();
    if (ocr) {
      final pixels = request.limits.checkedRasterPixels(width, height);
      if (pixels > request.limits.totalPixels - _pixels) {
        throw const DocumentException('document_raster_limit');
      }
      _pixels += pixels;
    } else if (width != 0 || height != 0) {
      _invalid();
    }
    final text = utf8.decode(Uint8List.sublistView(frame, 47));
    _outputBytes += textLength;
    _pages.add(
      DocumentWorkerPage(
        page: page,
        ocr: ocr,
        text: text,
        width: width,
        height: height,
      ),
    );
  }

  List<DocumentWorkerPage> finish() {
    if (_failed || !_terminal || _prefixUsed != 0 || _frame != null) {
      _invalid();
    }
    return List.unmodifiable(_pages);
  }

  Never _invalid() =>
      throw const DocumentException('invalid_document_worker_protocol');
}
