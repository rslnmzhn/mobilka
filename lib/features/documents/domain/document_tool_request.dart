import 'dart:convert';

import '../../memory/domain/strict_json_object_parser.dart';
import '../../workspace/domain/session_workspace_path.dart';
import 'document_limits.dart';
import 'document_snapshot.dart';
import 'document_worker_supervisor.dart';

enum DocumentToolOperation { extract, ocr }

enum DocumentToolInputFormat { csv, docx, xlsx, pdf, png, jpeg }

final class DocumentToolRequest {
  const DocumentToolRequest._({
    required this.operation,
    required this.path,
    required this.sourceHash,
    required this.format,
    required this.nativeOptions,
  });

  static const maxArgumentBytes = 4096;
  final DocumentToolOperation operation;
  final SessionWorkspacePath path;
  final String sourceHash;
  final DocumentToolInputFormat format;
  final DocumentWorkerOptions? nativeOptions;

  static DocumentToolRequest parse(String toolName, String rawArguments) {
    try {
      if (rawArguments.length > maxArgumentBytes ||
          utf8.encode(rawArguments).length > maxArgumentBytes) {
        throw const DocumentException('document_arguments_limit');
      }
      final operation = switch (toolName) {
        'extract_document' => DocumentToolOperation.extract,
        'ocr_document' => DocumentToolOperation.ocr,
        _ => throw const FormatException('tool'),
      };
      final args = StrictJsonObjectParser.decode(
        rawArguments,
        maxSourceBytes: maxArgumentBytes,
        maxDepth: 2,
        maxNodes: 20,
        maxStringBytes: maxArgumentBytes,
      );
      final allowed = {
        'path',
        'source_sha256',
        'format',
        'first_page',
        'page_count',
        if (operation == DocumentToolOperation.ocr) 'language',
      };
      if (args.keys.any((key) => !allowed.contains(key)) ||
          args['path'] is! String ||
          args['source_sha256'] is! String ||
          args['format'] is! String) {
        throw const FormatException('fields');
      }
      final path = SessionWorkspacePath.parse(args['path']! as String);
      final hash = args['source_sha256']! as String;
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
        throw const FormatException('hash');
      }
      final format = DocumentToolInputFormat.values.firstWhere(
        (value) => value.name == args['format'],
        orElse: () => throw const FormatException('format'),
      );
      final extension = path.components.last.split('.').last.toLowerCase();
      if (extension != format.name &&
          !(format == DocumentToolInputFormat.jpeg && extension == 'jpg')) {
        throw const FormatException('extension');
      }
      final image =
          format == DocumentToolInputFormat.png ||
          format == DocumentToolInputFormat.jpeg;
      final pdf = format == DocumentToolInputFormat.pdf;
      if ((operation == DocumentToolOperation.extract && image) ||
          (operation == DocumentToolOperation.ocr && !image && !pdf)) {
        throw const DocumentException('unsupported_document_type');
      }
      for (final key in ['first_page', 'page_count']) {
        if (args.containsKey(key) && args[key] is! int) {
          throw const FormatException('page');
        }
      }
      if (args.containsKey('language') && args['language'] != 'engRus') {
        throw const FormatException('language');
      }
      if (!pdf &&
          !image &&
          (args.containsKey('first_page') || args.containsKey('page_count'))) {
        throw const FormatException('local pages');
      }
      final options = pdf || image
          ? DocumentWorkerOptions(
              operation: operation == DocumentToolOperation.extract
                  ? DocumentWorkerOperation.pdfText
                  : pdf
                  ? DocumentWorkerOperation.pdfOcr
                  : DocumentWorkerOperation.imageOcr,
              language: DocumentWorkerLanguage.engRus,
              firstPage: args['first_page'] as int? ?? 1,
              pageCount: args['page_count'] as int? ?? 1,
            )
          : null;
      return DocumentToolRequest._(
        operation: operation,
        path: path,
        sourceHash: hash,
        format: format,
        nativeOptions: options,
      );
    } on FormatException {
      throw const DocumentException('invalid_document_arguments');
    }
  }

  void validateSnapshot(DocumentSnapshot snapshot) {
    if (path.value != snapshot.sourcePath.value ||
        sourceHash != snapshot.sha256Digest) {
      throw const DocumentException('document_snapshot_mismatch');
    }
  }
}
