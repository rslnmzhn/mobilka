import 'dart:convert';

import '../domain/document_extraction.dart';
import '../domain/document_limits.dart';
import 'bounded_document_xml.dart';

void parseXlsxDocument(DocumentPackageXml package, DocumentOutput output) {
  final part = package.mainPart(
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml',
    output.warnings,
  );
  final workbook = package.require(part);
  if (!workbook.isName(sheetNamespace, 'workbook')) _invalid();
  final relationships = package.relationships(part, output.warnings);
  final shared = <String>[];
  final stringRelationships = relationships.values
      .where((r) => r.type == '$relationshipNamespace/sharedStrings')
      .toList();
  if (stringRelationships.length > 1) _invalid();
  if (stringRelationships.isNotEmpty) {
    final target = stringRelationships.single.target;
    if (target == null) _invalid();
    final strings = package.require(target);
    if (!strings.isName(sheetNamespace, 'sst')) _invalid();
    for (final item in strings.children) {
      if (!item.isName(sheetNamespace, 'si')) _invalid();
      if (shared.length >= output.limits.cells) {
        throw const DocumentException('document_table_limit');
      }
      shared.add(_richText(item, output));
    }
  }
  final containers = workbook.children
      .where((n) => n.isName(sheetNamespace, 'sheets'))
      .toList();
  if (containers.length != 1) _invalid();
  var sheetCount = 0;
  final sheetNames = <String>{};
  final sheetIds = <String>{};
  final targets = <String>{};
  for (final sheet in containers.single.children) {
    if (!sheet.isName(sheetNamespace, 'sheet')) _invalid();
    if (++sheetCount > output.limits.sheets) {
      throw const DocumentException('document_table_limit');
    }
    final name = sheet.attribute('name');
    final id = sheet.attribute('id', namespace: relationshipNamespace);
    final sheetId = sheet.attribute('sheetId');
    final state = sheet.attribute('state') ?? 'visible';
    if (name == null ||
        name.isEmpty ||
        name.length > 31 ||
        !sheetNames.add(name.toLowerCase()) ||
        sheetId == null ||
        !sheetIds.add(sheetId) ||
        id == null ||
        !const {'visible', 'hidden', 'veryHidden'}.contains(state)) {
      _invalid();
    }
    final relationship = relationships[id];
    if (relationship == null ||
        relationship.target == null ||
        relationship.type != '$relationshipNamespace/worksheet') {
      _invalid();
    }
    final target = relationship.target!;
    if (!targets.add(target)) _invalid();
    final root = package.require(target);
    if (!root.isName(sheetNamespace, 'worksheet')) _invalid();
    package.relationships(target, output.warnings);
    final data = root.children
        .where((n) => n.isName(sheetNamespace, 'sheetData'))
        .toList();
    if (data.length != 1) _invalid();
    final seenRows = <int>{};
    var previousRow = 0;
    for (final row in data.single.children) {
      if (!row.isName(sheetNamespace, 'row')) _invalid();
      final rowNumber = int.tryParse(
        row.attribute('r') ?? '${previousRow + 1}',
      );
      if (rowNumber == null ||
          rowNumber < 1 ||
          rowNumber > output.limits.rows ||
          !seenRows.add(rowNumber)) {
        _invalid();
      }
      previousRow = rowNumber;
      var previousColumn = 0;
      final seenColumns = <int>{};
      for (final cell in row.children) {
        if (!cell.isName(sheetNamespace, 'c')) _invalid();
        var column = previousColumn + 1;
        final reference = cell.attribute('r');
        if (reference != null) {
          final match = RegExp(
            r'^([A-Z]{1,3})([1-9][0-9]{0,6})$',
          ).firstMatch(reference);
          if (match == null || int.parse(match.group(2)!) != rowNumber) {
            _invalid();
          }
          column = 0;
          for (final unit in match.group(1)!.codeUnits) {
            column = column * 26 + unit - 64;
          }
        }
        if (column > output.limits.columns || !seenColumns.add(column)) {
          throw const DocumentException('document_table_limit');
        }
        previousColumn = column;
        final values = cell.children
            .where((n) => n.isName(sheetNamespace, 'v'))
            .toList();
        final formulas = cell.children
            .where((n) => n.isName(sheetNamespace, 'f'))
            .toList();
        if (values.length > 1 || formulas.length > 1) _invalid();
        final formula = formulas.isEmpty ? null : formulas.single.text;
        final kind = cell.attribute('t') ?? 'n';
        var value = values.isEmpty ? '' : values.single.text;
        switch (kind) {
          case 's':
            final index = int.tryParse(value);
            if (index == null || index < 0 || index >= shared.length) {
              _invalid();
            }
            value = shared[index];
          case 'inlineStr':
            final inline = cell.children
                .where((n) => n.isName(sheetNamespace, 'is'))
                .toList();
            if (inline.length != 1 || values.isNotEmpty) _invalid();
            value = _richText(inline.single, output);
          case 'b':
            if (value != '0' && value != '1' && value.isNotEmpty) _invalid();
          case 'n':
            if (value.isNotEmpty &&
                (double.tryParse(value)?.isFinite != true)) {
              _invalid();
            }
          case 'str':
          case 'e':
          case 'd':
            break;
          default:
            _invalid();
        }
        if (formula != null) {
          output.warnings.add(
            values.isEmpty
                ? 'xlsx_formula_without_cache'
                : 'xlsx_formula_cache_may_be_stale',
          );
        }
        output.add(
          DocumentFragment(
            text: value,
            part: target,
            sheet: name,
            sheetVisibility: state,
            row: rowNumber,
            column: column,
            formula: formula,
            valueType: kind,
          ),
        );
      }
    }
  }
  output.warnings.add('xlsx_raw_values_without_layout_or_date_formatting');
}

String _richText(DocumentXmlNode node, DocumentOutput output) {
  final buffer = StringBuffer();
  for (final child in node.children) {
    final texts = child.isName(sheetNamespace, 't')
        ? [child]
        : child.isName(sheetNamespace, 'r')
        ? child.children.where((n) => n.isName(sheetNamespace, 't'))
        : <DocumentXmlNode>[];
    for (final text in texts) {
      if (buffer.length + text.text.length > output.limits.cellBytes) {
        throw const DocumentException('document_output_limit');
      }
      buffer.write(text.text);
    }
  }
  final result = buffer.toString();
  if (utf8.encode(result).length > output.limits.cellBytes) {
    throw const DocumentException('document_output_limit');
  }
  return result;
}

Never _invalid() => throw const DocumentException('invalid_xlsx');
