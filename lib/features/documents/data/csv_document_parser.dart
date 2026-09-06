import 'dart:convert';

import '../domain/document_extraction.dart';
import '../domain/document_limits.dart';
import '../domain/document_snapshot.dart';

void parseCsvDocument(
  DocumentSnapshot snapshot,
  DocumentOutput output, {
  String delimiter = ',',
}) {
  if (!const {',', ';', '\t'}.contains(delimiter)) {
    throw const DocumentException('invalid_csv_delimiter');
  }
  String text;
  try {
    text = utf8.decode(snapshot.bytes, allowMalformed: false);
  } on FormatException {
    throw const DocumentException('unsupported_document_encoding');
  }
  if (text.startsWith('\ufeff')) text = text.substring(1);
  if (text.contains('\u0000')) {
    throw const DocumentException('invalid_csv');
  }
  if (text.isEmpty) return;
  var row = 1;
  var column = 1;
  var quoted = false;
  var closed = false;
  var atStart = true;
  var endedRow = false;
  var field = StringBuffer();

  void emit() {
    if (row > output.limits.rows || column > output.limits.columns) {
      throw const DocumentException('document_table_limit');
    }
    output.add(
      DocumentFragment(
        text: field.toString(),
        part: 'csv',
        row: row,
        column: column,
        valueType: 'text',
      ),
    );
    field = StringBuffer();
    atStart = true;
    closed = false;
  }

  void append(String value) {
    // UTF-16 length is a lower bound for valid UTF-8 size; the exact limit is
    // checked on emission, without allowing an unbounded field buffer.
    if (field.length + value.length > output.limits.cellBytes) {
      throw const DocumentException('document_output_limit');
    }
    field.write(value);
  }

  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    endedRow = false;
    if (quoted) {
      if (char == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          append('"');
          i++;
        } else {
          quoted = false;
          closed = true;
        }
      } else {
        append(char);
      }
      continue;
    }
    if (char == delimiter) {
      emit();
      column++;
    } else if (char == '\r' || char == '\n') {
      if (char == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      emit();
      row++;
      column = 1;
      endedRow = true;
    } else if (char == '"' && atStart && !closed) {
      quoted = true;
      atStart = false;
    } else {
      if (closed || char == '"') throw const DocumentException('invalid_csv');
      atStart = false;
      append(char);
    }
  }
  if (quoted) throw const DocumentException('invalid_csv');
  if (!endedRow) emit();
}
