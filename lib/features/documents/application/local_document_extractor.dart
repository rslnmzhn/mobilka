import '../data/bounded_document_xml.dart';
import '../data/bounded_ooxml_package.dart';
import '../data/csv_document_parser.dart';
import '../data/docx_document_parser.dart';
import '../data/xlsx_document_parser.dart';
import '../domain/document_extraction.dart';
import '../domain/document_limits.dart';
import '../domain/document_snapshot.dart';

final class LocalDocumentExtractor {
  LocalDocumentExtractor({DocumentLimits? limits})
    : limits = limits ?? DocumentLimits();
  final DocumentLimits limits;

  DocumentExtraction extract(
    DocumentSnapshot snapshot, {
    String csvDelimiter = ',',
  }) {
    if (snapshot.byteCount > limits.sourceBytes) {
      throw const DocumentException('document_source_limit');
    }
    final extension = snapshot.sourcePath.components.last
        .split('.')
        .last
        .toLowerCase();
    final format = switch (extension) {
      'csv' => DocumentFormat.csv,
      'docx' => DocumentFormat.docx,
      'xlsx' => DocumentFormat.xlsx,
      _ => throw const DocumentException('unsupported_document_type'),
    };
    final output = DocumentOutput(limits);
    if (format == DocumentFormat.csv) {
      parseCsvDocument(snapshot, output, delimiter: csvDelimiter);
    } else {
      final package = DocumentPackageXml(
        BoundedOoxmlPackage.read(snapshot.bytes, limits),
        limits,
      );
      if (format == DocumentFormat.docx) {
        parseDocxDocument(package, output);
      } else {
        parseXlsxDocument(package, output);
      }
    }
    return DocumentExtraction(
      snapshot: snapshot,
      format: format,
      optionsIdentity: format == DocumentFormat.csv
          ? 'utf8;delimiter=${csvDelimiter.codeUnits.join(',')}'
          : 'utf8;raw-values',
      fragments: output.fragments,
      warnings: output.warnings,
    );
  }
}
