import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'document_limits.dart';
import 'document_snapshot.dart';

enum DocumentFormat { csv, docx, xlsx }

final class NativeDocumentPage {
  const NativeDocumentPage({
    required this.page,
    required this.ocr,
    required this.text,
  });

  final int page;
  final bool ocr;
  final String text;
}

final class NativeDocumentExtraction {
  NativeDocumentExtraction({
    required this.snapshot,
    required this.optionsHash,
    required List<NativeDocumentPage> pages,
  }) : pages = List.unmodifiable(pages);

  final DocumentSnapshot snapshot;
  final String optionsHash;
  final List<NativeDocumentPage> pages;
}

final class DocumentFragment {
  const DocumentFragment({
    required this.text,
    required this.part,
    this.paragraph,
    this.table,
    this.sheet,
    this.sheetVisibility,
    this.row,
    this.column,
    this.formula,
    this.valueType,
  });

  final String text;
  final String part;
  final int? paragraph;
  final int? table;
  final String? sheet;
  final String? sheetVisibility;
  final int? row;
  final int? column;
  final String? formula;
  final String? valueType;

  List<Object?> get digestFields => [
    text,
    part,
    paragraph,
    table,
    sheet,
    sheetVisibility,
    row,
    column,
    formula,
    valueType,
  ];
}

final class DocumentExtraction {
  DocumentExtraction({
    required this.snapshot,
    required this.format,
    required this.optionsIdentity,
    required List<DocumentFragment> fragments,
    required Set<String> warnings,
  }) : fragments = List.unmodifiable(fragments),
       warnings = Set.unmodifiable(warnings),
       outputDigest = sha256
           .convert(
             utf8.encode(
               jsonEncode([
                 'local-document/1',
                 format.name,
                 optionsIdentity,
                 snapshot.sha256Digest,
                 fragments.map((fragment) => fragment.digestFields).toList(),
                 warnings.toList()..sort(),
               ]),
             ),
           )
           .toString();

  static const extractorIdentity = 'local-document/1';
  final DocumentSnapshot snapshot;
  final DocumentFormat format;
  final String optionsIdentity;
  final List<DocumentFragment> fragments;
  final Set<String> warnings;
  final String outputDigest;
  bool get complete => warnings.isEmpty;
}

final class DocumentOutput {
  DocumentOutput(this.limits);
  final DocumentLimits limits;
  final List<DocumentFragment> fragments = [];
  final Set<String> warnings = {};
  int _bytes = 0;

  void add(DocumentFragment fragment) {
    final textBytes = utf8.encode(fragment.text).length;
    final formulaBytes = utf8.encode(fragment.formula ?? '').length;
    if (textBytes > limits.cellBytes ||
        formulaBytes > limits.cellBytes ||
        _bytes + textBytes + formulaBytes > limits.outputBytes ||
        fragments.length >= limits.cells) {
      throw const DocumentException('document_output_limit');
    }
    _bytes += textBytes + formulaBytes;
    fragments.add(fragment);
  }
}
