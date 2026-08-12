import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/agents/data/agent_definition_parser.dart';
import 'package:mobilka/features/agents/data/agent_import_picker.dart';

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('agent-import-'),
  );
  tearDown(() => root.delete(recursive: true));

  test('returns null when the picker is cancelled', () async {
    expect(await AgentImportPicker(picker: () async => null).pick(), isNull);
  });

  test('preflights oversized imports before bounded parsing', () async {
    final file = File('${root.path}${Platform.pathSeparator}large.md');
    await file.writeAsBytes(
      List.filled(AgentDefinitionParser.maxDocumentBytes + 1, 97),
    );

    await expectLater(
      AgentImportPicker(picker: () async => XFile(file.path)).pick(),
      throwsA(isA<AgentDefinitionFormatException>()),
    );
  });
}
