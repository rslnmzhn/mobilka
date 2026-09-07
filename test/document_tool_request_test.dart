import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/document_tool_definitions.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/documents/domain/document_limits.dart';
import 'package:mobilka/features/documents/domain/document_tool_request.dart';
import 'package:mobilka/features/documents/domain/document_worker_supervisor.dart';

void main() {
  final hash = List.filled(64, 'a').join();
  Map<String, Object?> args(String format) => {
    'path': 'input.$format',
    'source_sha256': hash,
    'format': format,
  };
  final invalid = throwsA(isA<DocumentException>());

  test('stable pure definitions are read-only closed objects', () {
    expect(documentToolDefinitions.map((d) => d.name), [
      'extract_document',
      'ocr_document',
    ]);
    for (final definition in documentToolDefinitions) {
      expect(definition.effect, ChatToolEffect.readOnly);
      expect(definition.parameters['type'], 'object');
      expect(definition.parameters['additionalProperties'], false);
      expect(definition.parameters['required'], [
        'path',
        'source_sha256',
        'format',
      ]);
      final properties = definition.parameters['properties'] as Map;
      expect(properties.keys, isNot(contains('session')));
      expect(properties.keys, isNot(contains('root')));
      expect(properties.keys, isNot(contains('url')));
      final formats = (properties['format'] as Map)['enum'] as List;
      expect(
        formats,
        definition.name == 'extract_document'
            ? ['csv', 'docx', 'xlsx', 'pdf']
            : ['png', 'jpeg', 'pdf'],
      );
      for (final format in formats.cast<String>()) {
        expect(
          DocumentToolRequest.parse(
            definition.name,
            jsonEncode(args(format)),
          ).format.name,
          format,
        );
      }
      expect(definition.toJson()['type'], 'function');
    }
  });

  test('rejects unknown, duplicate, malformed and non-object arguments', () {
    final valid = jsonEncode(args('csv'));
    for (final raw in [
      '[]',
      'null',
      '1',
      '$valid trailing',
      '${valid.substring(0, valid.length - 1)},"path":"input.csv"}',
      '${valid.substring(0, valid.length - 1)},"pa\\u0074h":"input.csv"}',
      jsonEncode({...args('csv'), 'root': 'elsewhere'}),
      jsonEncode({...args('csv'), 'url': 'https://example.com'}),
      jsonEncode({...args('csv'), 'session': 'other'}),
      jsonEncode({...args('csv'), 'path': 1}),
      jsonEncode({...args('csv'), 'source_sha256': null}),
      jsonEncode({...args('csv'), 'source_sha256': hash.toUpperCase()}),
      jsonEncode({...args('csv'), 'format': 'CSV'}),
      jsonEncode({...args('csv'), 'language': 'engRus'}),
    ]) {
      expect(() => DocumentToolRequest.parse('extract_document', raw), invalid);
    }
    expect(() => DocumentToolRequest.parse('other', valid), invalid);
  });

  test('rejects root, traversal, URL and mismatched extension selectors', () {
    for (final path in [
      '',
      '/',
      '../input.csv',
      'a/../input.csv',
      r'C:\input.csv',
      'https://host/input.csv',
      'input.png',
      'a//input.csv',
    ]) {
      expect(
        () => DocumentToolRequest.parse(
          'extract_document',
          jsonEncode({...args('csv'), 'path': path}),
        ),
        invalid,
      );
    }
  });

  test('caps raw code units and wire bytes before JSON parsing', () {
    for (final raw in [
      List.filled(4097, ' ').join(),
      List.filled(2100, 'я').join(),
    ]) {
      expect(
        () => DocumentToolRequest.parse('extract_document', raw),
        throwsA(
          isA<DocumentException>().having(
            (e) => e.code,
            'code',
            'document_arguments_limit',
          ),
        ),
      );
    }
  });

  test('fixed RU+EN and bounded contiguous page subset', () {
    final request = DocumentToolRequest.parse(
      'ocr_document',
      jsonEncode({
        ...args('pdf'),
        'first_page': 76,
        'page_count': 25,
        'language': 'engRus',
      }),
    );
    expect(request.nativeOptions!.operation, DocumentWorkerOperation.pdfOcr);
    expect(request.nativeOptions!.language, DocumentWorkerLanguage.engRus);
    expect(request.nativeOptions!.firstPage, 76);
    expect(request.nativeOptions!.pageCount, 25);
    for (final changes in <Map<String, Object?>>[
      {'first_page': 0},
      {'first_page': 101},
      {'page_count': 0},
      {'page_count': 26},
      {'first_page': 77, 'page_count': 25},
      {'first_page': 1.0},
      {'page_count': '1'},
      {'page_count': null},
      {'language': 'eng'},
      {'language': 'rus'},
      {'language': null},
    ]) {
      expect(
        () => DocumentToolRequest.parse(
          'ocr_document',
          jsonEncode({...args('pdf'), ...changes}),
        ),
        invalid,
      );
    }
    for (final format in ['png', 'jpeg']) {
      expect(
        () => DocumentToolRequest.parse(
          'ocr_document',
          jsonEncode({...args(format), 'page_count': 2}),
        ),
        invalid,
      );
      expect(
        () => DocumentToolRequest.parse(
          'extract_document',
          jsonEncode(args(format)),
        ),
        invalid,
      );
    }
    expect(
      () => DocumentToolRequest.parse(
        'extract_document',
        jsonEncode({...args('csv'), 'first_page': 1}),
      ),
      invalid,
    );
    expect(
      () => DocumentToolRequest.parse('ocr_document', jsonEncode(args('docx'))),
      invalid,
    );
    expect(
      DocumentToolRequest.parse(
        'ocr_document',
        jsonEncode({...args('jpeg'), 'path': 'photo.JPG'}),
      ).nativeOptions!.operation,
      DocumentWorkerOperation.imageOcr,
    );
  });
}
