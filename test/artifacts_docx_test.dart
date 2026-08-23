import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/artifacts/application/artifact_policy.dart';
import 'package:mobilka/features/artifacts/application/artifacts_chat_tool_runtime.dart';
import 'package:mobilka/features/artifacts/application/artifacts_controller.dart';
import 'package:mobilka/features/artifacts/application/markdown_docx_converter.dart';
import 'package:mobilka/features/artifacts/data/artifact_store.dart';
import 'package:mobilka/features/artifacts/data/local_artifact_files.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory filesDir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mobilka-docx');
    filesDir = Directory(p.join(root.path, 'files'));
    await filesDir.create();
    Hive.init(p.join(root.path, 'hive'));
    await Hive.openBox<dynamic>('artifacts');
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk('artifacts');
    await Hive.close();
    await root.delete(recursive: true);
  });

  LocalArtifactFiles files() =>
      LocalArtifactFiles(baseDirectory: () => filesDir);

  const markdown =
      '# Report\n\nSome **bold** and *italic* text with '
      '<tags> & "quotes".\n\n- first bullet\n- second bullet\n\n'
      '1. step one\n2. step two\n\n```dart\nvoid main() {}\n```\n\n'
      '> quoted line\n\n---\n\nPlain closing paragraph.';

  group('MarkdownDocxConverter', () {
    test('produces a zip with required OOXML parts', () {
      final bytes = const MarkdownDocxConverter().generate(
        title: 'Report',
        markdown: markdown,
      );

      final archive = ZipDecoder().decodeBytes(bytes);
      final names = archive.files.map((file) => file.name).toSet();
      expect(
        names,
        containsAll([
          '[Content_Types].xml',
          '_rels/.rels',
          'word/document.xml',
          'word/styles.xml',
        ]),
      );
    });

    test('converts headings lists code quotes and inline styles', () {
      final document = _documentXml(
        const MarkdownDocxConverter().generate(
          title: 'Report',
          markdown: markdown,
        ),
      );

      expect(document, contains('Heading1'));
      expect(document, contains('>Report<'));
      expect(document, contains('<w:b/>'));
      expect(document, contains('<w:i/>'));
      expect(document, contains('&lt;tags&gt; &amp; &quot;quotes&quot;.'));
      expect(document, contains('• first bullet'));
      expect(document, contains('>1. step one<'));
      expect(document, contains('>2. step two<'));
      expect(document, contains('>void main() {}<'));
      expect(document, contains('CodeBlock'));
      expect(document, contains('QuoteBlock'));
      expect(document, contains('>quoted line<'));
    });
  });

  group('ArtifactsChatToolRuntime', () {
    ProviderContainer container() {
      final providerContainer = ProviderContainer(
        overrides: [localArtifactFilesProvider.overrideWithValue(files())],
      );
      addTearDown(providerContainer.dispose);
      return providerContainer;
    }

    ChatToolCall call(String arguments) => ChatToolCall(
      id: 'call-docx',
      name: 'generate_docx',
      arguments: arguments,
    );

    test('advertises generate_docx only when allowed', () async {
      final runtime = container().read(artifactsChatToolRuntimeProvider);

      expect(await runtime.availableTools(const {'generate_docx'}), isNotEmpty);
      expect(
        await runtime.availableTools(const {'update_memory_file'}),
        isEmpty,
      );
    });

    test('executeTool creates md artifact and docx sibling', () async {
      final providerContainer = container();
      final runtime = providerContainer.read(artifactsChatToolRuntimeProvider);

      final result = await runtime.executeTool(
        call(jsonEncode({'title': 'Report', 'markdown': '# Report\n\nBody'})),
        const {'generate_docx'},
      );
      final decoded = jsonDecode(result) as Map;

      expect(decoded['ok'], true);
      final artifacts = providerContainer
          .read(artifactsControllerProvider)
          .map((item) => item.title);
      expect(artifacts, ['Report']);
      final docx = File(
        p.join(filesDir.path, '${decoded['artifact_id']}.docx'),
      );
      expect(docx.existsSync(), isTrue);
      final md = File(p.join(filesDir.path, '${decoded['artifact_id']}.md'));
      expect(md.readAsStringSync(), startsWith('# Report'));
    });

    test(
      'policy violations return a failed envelope without residue',
      () async {
        final providerContainer = container();
        final runtime = providerContainer.read(
          artifactsChatToolRuntimeProvider,
        );

        final result = await runtime.executeTool(
          call(
            jsonEncode({
              'title': 'Too big',
              // Pinned build_runner cannot parse digit-separated literals here.
              'markdown': 'a' * (ArtifactPolicy.maxContentBytes + 1),
            }),
          ),
          const {'generate_docx'},
        );
        final decoded = jsonDecode(result) as Map;

        expect(decoded['ok'], false);
        expect(decoded['error'], 'artifacts.errorContentTooLarge');
        expect(providerContainer.read(artifactsControllerProvider), isEmpty);
        expect(filesDir.listSync().whereType<File>(), isEmpty);
      },
    );

    test('disallowed execution throws a permission error', () async {
      final runtime = container().read(artifactsChatToolRuntimeProvider);

      expect(
        () => runtime.executeTool(call('{}'), const {}),
        throwsA(isA<ArtifactsToolPermissionException>()),
      );
    });
  });
}

String _documentXml(List<int> docxBytes) {
  final archive = ZipDecoder().decodeBytes(docxBytes);
  return utf8.decode(
    archive.files.firstWhere((file) => file.name == 'word/document.xml').content
        as List<int>,
  );
}
