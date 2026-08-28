import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:mobilka/features/artifacts/domain/artifact.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/application/workspace_paths.dart';
import 'package:path/path.dart' as p;
import 'package:saf/saf.dart';

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
    await Hive.openBox<dynamic>('preferences');
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
          'word/_rels/document.xml.rels',
          'word/document.xml',
          'word/styles.xml',
          'docProps/core.xml',
          'docProps/app.xml',
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

    ProviderContainer workspaceContainer(
      Directory workspace, {
      PathMemoryFileStoreHooks? hooks,
    }) {
      Hive.box<dynamic>('preferences')
        ..put('memoryLocation', workspace.path)
        ..put('memoryLocationIsUri', false);
      final repository = MemoryRepository(
        Saf(),
        boundaryFactory: (_) =>
            PathMemoryFileStore(workspace.path, hooks: hooks),
      );
      final providerContainer = ProviderContainer(
        overrides: [
          localArtifactFilesProvider.overrideWithValue(files()),
          memoryRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(providerContainer.dispose);
      return providerContainer;
    }

    ProviderContainer safWorkspaceContainer(_ArtifactSafAccess access) {
      const bareTreeUri =
          'content://com.android.externalstorage.documents/tree/primary%3AMemory';
      const rootDocumentUri =
          '$bareTreeUri/document/primary%3AMemory';
      Hive.box<dynamic>('preferences')
        ..put('memoryLocation', rootDocumentUri)
        ..put('memoryLocationIsUri', true);
      final repository = MemoryRepository(
        Saf(),
        persistedPermissions: () async => const [
          SafPersistedPermission(
            uri: bareTreeUri,
            read: true,
            write: true,
            persistedTime: 0,
          ),
        ],
        boundaryFactory: (_) => SafMemoryFileStore(rootDocumentUri, access),
      );
      final providerContainer = ProviderContainer(
        overrides: [
          localArtifactFilesProvider.overrideWithValue(files()),
          memoryRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(providerContainer.dispose);
      return providerContainer;
    }

    ChatToolCall call(String arguments) => ChatToolCall(
      id: 'call-docx',
      name: 'generate_docx',
      arguments: arguments,
    );

    WorkspaceBinding binding(ProviderContainer container) => WorkspaceStore(
      repository: container.read(memoryRepositoryProvider),
    ).captureBinding()!;

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
      expect(decoded['workspace_saved'], false);
    });

    test('mirrors exact siblings into immutable supplied session', () async {
      final workspace = Directory(p.join(root.path, 'workspace'))..createSync();
      final changedWorkspace = Directory(p.join(root.path, 'changed'))
        ..createSync();
      final providerContainer = workspaceContainer(workspace);
      final runtime = providerContainer.read(artifactsChatToolRuntimeProvider);
      final capturedBinding = binding(providerContainer);
      await Hive.box<dynamic>(
        'preferences',
      ).put('memoryLocation', changedWorkspace.path);

      final result =
          jsonDecode(
                await runtime.executeTool(
                  call(
                    jsonEncode({
                      'title': 'Model title',
                      'markdown': '# Exact\nBody',
                    }),
                  ),
                  const {'generate_docx'},
                  context: ChatToolExecutionContext(
                    conversationId: 'changed-later-does-not-matter',
                    sessionKey: 'immutable-session',
                    workspaceBinding: capturedBinding,
                  ),
                ),
              )
              as Map;

      expect(result['workspace_saved'], true);
      final id = result['artifact_id'] as String;
      final mirrored = Directory(
        p.join(workspace.path, 'sessions', 'immutable-session', 'artifacts'),
      );
      expect(
        File(p.join(mirrored.path, '$id.md')).readAsStringSync(),
        '# Exact\nBody',
      );
      expect(
        File(p.join(mirrored.path, '$id.docx')).readAsBytesSync(),
        File(p.join(filesDir.path, '$id.docx')).readAsBytesSync(),
      );
      expect(mirrored.listSync().map((item) => p.basename(item.path)), {
        '$id.md',
        '$id.docx',
      });
      expect(changedWorkspace.listSync(recursive: true), isEmpty);
    });

    test('workspace collision returns a safe tool envelope', () async {
      final workspace = Directory(p.join(root.path, 'workspace'))..createSync();
      final fixedNow = DateTime.utc(2026, 8, 27);
      final id = '${fixedNow.microsecondsSinceEpoch}-artifact';
      final existing = File(
        p.join(workspace.path, 'sessions', 'stable-key', 'artifacts', '$id.md'),
      )..createSync(recursive: true);
      existing.writeAsBytesSync([9, 8, 7]);
      Hive.box<dynamic>('preferences')
        ..put('memoryLocation', workspace.path)
        ..put('memoryLocationIsUri', false);
      final providerContainer = ProviderContainer(
        overrides: [
          localArtifactFilesProvider.overrideWithValue(files()),
          memoryRepositoryProvider.overrideWithValue(
            MemoryRepository(
              Saf(),
              boundaryFactory: (_) => PathMemoryFileStore(workspace.path),
            ),
          ),
          artifactsControllerProvider.overrideWith(
            () => ArtifactsController(clock: () => fixedNow),
          ),
        ],
      );
      addTearDown(providerContainer.dispose);

      final result =
          jsonDecode(
                await providerContainer
                    .read(artifactsChatToolRuntimeProvider)
                    .executeTool(
                      call(jsonEncode({'title': 'Safe', 'markdown': 'new'})),
                      const {'generate_docx'},
                      context: ChatToolExecutionContext(
                        conversationId: 'conversation',
                        sessionKey: 'stable-key',
                        workspaceBinding: binding(providerContainer),
                      ),
                    ),
              )
              as Map;

      expect(result['ok'], true);
      expect(result['artifact_id'], id);
      expect(result['workspace_saved'], false);
      expect(result['workspace_status'], contains('collision'));
      expect(existing.readAsBytesSync(), [9, 8, 7]);
      expect(
        File(p.join(existing.parent.path, '$id.docx')).existsSync(),
        false,
      );
    });

    test(
      'DOCX write failure leaves no app-private residue and retry is clean',
      () async {
        final failingFiles = _FailingDocxFiles(filesDir);
        final providerContainer = ProviderContainer(
          overrides: [
            localArtifactFilesProvider.overrideWithValue(failingFiles),
          ],
        );
        addTearDown(providerContainer.dispose);
        final controller = providerContainer.read(
          artifactsControllerProvider.notifier,
        );

        await expectLater(
          controller.createDocxArtifact(title: 'Retry', markdown: 'body'),
          throwsA(isA<FileSystemException>()),
        );
        expect(providerContainer.read(artifactsControllerProvider), isEmpty);
        expect(Hive.box<dynamic>('artifacts').isEmpty, true);
        expect(filesDir.listSync().whereType<File>(), isEmpty);

        failingFiles.failDocx = false;
        await controller.createDocxArtifact(title: 'Retry', markdown: 'body');
        expect(
          providerContainer.read(artifactsControllerProvider),
          hasLength(1),
        );
        expect(filesDir.listSync().whereType<File>(), hasLength(2));
      },
    );

    test('metadata failure cleans both files and preserves state', () async {
      final store = _FailingArtifactStore();
      final providerContainer = ProviderContainer(
        overrides: [
          localArtifactFilesProvider.overrideWithValue(files()),
          artifactStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(providerContainer.dispose);
      final controller = providerContainer.read(
        artifactsControllerProvider.notifier,
      );

      await expectLater(
        controller.createDocxArtifact(title: 'Failed', markdown: 'body'),
        throwsStateError,
      );
      expect(providerContainer.read(artifactsControllerProvider), isEmpty);
      expect(filesDir.listSync().whereType<File>(), isEmpty);
    });

    test(
      'rollback collision preserves an existing artifact and files',
      () async {
        final fixedNow = DateTime.utc(2026, 8, 27);
        final existingId = '${fixedNow.microsecondsSinceEpoch}-artifact';
        final existing = Artifact(
          id: existingId,
          title: 'Existing',
          content: 'valid',
          createdAt: fixedNow,
          updatedAt: fixedNow,
        );
        final store = ArtifactStore();
        await store.save(existing);
        await files().write(existingId, existing.content);
        await files().writeBytes(existingId, [1, 2, 3], extension: 'docx');
        final failingFiles = _FailingDocxFiles(filesDir);
        final providerContainer = ProviderContainer(
          overrides: [
            localArtifactFilesProvider.overrideWithValue(failingFiles),
            artifactStoreProvider.overrideWithValue(store),
            artifactsControllerProvider.overrideWith(
              () => ArtifactsController(clock: () => fixedNow),
            ),
          ],
        );
        addTearDown(providerContainer.dispose);

        await expectLater(
          providerContainer
              .read(artifactsControllerProvider.notifier)
              .createDocxArtifact(title: 'Failed', markdown: 'new'),
          throwsA(isA<FileSystemException>()),
        );

        expect(store.loadAll().single.id, existingId);
        expect(
          await File(p.join(filesDir.path, '$existingId.md')).readAsString(),
          'valid',
        );
        expect(
          await File(p.join(filesDir.path, '$existingId.docx')).readAsBytes(),
          [1, 2, 3],
        );
        expect(filesDir.listSync().whereType<File>(), hasLength(2));
      },
    );

    test('metadata delete failure reports incomplete rollback', () async {
      final store = _FailingArtifactStore(failDelete: true);
      final providerContainer = ProviderContainer(
        overrides: [
          localArtifactFilesProvider.overrideWithValue(files()),
          artifactStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(providerContainer.dispose);

      await expectLater(
        providerContainer
            .read(artifactsControllerProvider.notifier)
            .createDocxArtifact(title: 'Failed', markdown: 'body'),
        throwsA(
          isA<ArtifactRollbackException>()
              .having((error) => error.metadataAbsent, 'metadata absent', false)
              .having(
                (error) => error.cleanupHadErrors,
                'cleanup errors',
                true,
              ),
        ),
      );
      expect(providerContainer.read(artifactsControllerProvider), hasLength(1));
      expect(filesDir.listSync().whereType<File>(), isEmpty);
    });

    test(
      'file delete failure preserves authoritative metadata state',
      () async {
        final failingFiles = _FailingDeleteFiles(filesDir);
        final providerContainer = ProviderContainer(
          overrides: [
            localArtifactFilesProvider.overrideWithValue(failingFiles),
            artifactStoreProvider.overrideWithValue(_FailingArtifactStore()),
          ],
        );
        addTearDown(providerContainer.dispose);

        await expectLater(
          providerContainer
              .read(artifactsControllerProvider.notifier)
              .createDocxArtifact(title: 'Failed', markdown: 'body'),
          throwsA(
            isA<ArtifactRollbackException>()
                .having(
                  (error) => error.metadataAbsent,
                  'metadata absent',
                  true,
                )
                .having(
                  (error) => error.markdownAbsent,
                  'markdown absent',
                  false,
                ),
          ),
        );
        expect(providerContainer.read(artifactsControllerProvider), isEmpty);
      },
    );

    test(
      'invalid session only affects mirror and warning leaks no path',
      () async {
        final workspace = Directory(p.join(root.path, 'workspace'))
          ..createSync();
        final providerContainer = workspaceContainer(workspace);
        final result =
            jsonDecode(
                  await providerContainer
                      .read(artifactsChatToolRuntimeProvider)
                      .executeTool(
                        call(
                          jsonEncode({'title': '../Title', 'markdown': 'safe'}),
                        ),
                        const {'generate_docx'},
                        context: ChatToolExecutionContext(
                          conversationId: 'conversation',
                          sessionKey: '../escape',
                          workspaceBinding: binding(providerContainer),
                        ),
                      ),
                )
                as Map;

        expect(result['ok'], true);
        expect(result['workspace_saved'], false);
        expect(result['workspace_status'], isNot(contains(workspace.path)));
        expect(
          File(
            p.join(filesDir.path, '${result['artifact_id']}.docx'),
          ).existsSync(),
          isTrue,
        );
        expect(Directory(p.join(root.path, 'escape')).existsSync(), isFalse);
      },
    );

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

    test('second mirror failure preserves app artifact', () async {
      final workspace = Directory(p.join(root.path, 'workspace'))..createSync();
      final providerContainer = workspaceContainer(
        workspace,
        hooks: PathMemoryFileStoreHooks(
          afterTemporaryCreated: (temporary, destination) async {
            if (destination.path.endsWith('.docx')) {
              throw const FileSystemException('simulated mirror failure');
            }
          },
        ),
      );
      final result =
          jsonDecode(
                await providerContainer
                    .read(artifactsChatToolRuntimeProvider)
                    .executeTool(
                      call(
                        jsonEncode({'title': 'Partial', 'markdown': 'source'}),
                      ),
                      const {'generate_docx'},
                      context: ChatToolExecutionContext(
                        conversationId: 'conversation',
                        sessionKey: 'stable-key',
                        workspaceBinding: binding(providerContainer),
                      ),
                    ),
              )
              as Map;
      final id = result['artifact_id'] as String;

      expect(result['ok'], true);
      expect(result['workspace_saved'], false);
      expect(result['workspace_status'], contains('indeterminate'));
      expect(File(p.join(filesDir.path, '$id.md')).existsSync(), true);
      expect(File(p.join(filesDir.path, '$id.docx')).existsSync(), true);
    });

    test(
      'SAF verified Markdown and unreadable DOCX return indeterminate envelope',
      () async {
        final providerContainer = safWorkspaceContainer(
          _ArtifactSafAccess()..unreadableSuffix = '.docx',
        );
        final result =
            jsonDecode(
                  await providerContainer
                      .read(artifactsChatToolRuntimeProvider)
                      .executeTool(
                        call(
                          jsonEncode({
                            'title': 'Indeterminate',
                            'markdown': 'source',
                          }),
                        ),
                        const {'generate_docx'},
                        context: ChatToolExecutionContext(
                          conversationId: 'conversation',
                          sessionKey: 'stable-key',
                          workspaceBinding: binding(providerContainer),
                        ),
                      ),
                )
                as Map;

        expect(result['ok'], true);
        expect(result['workspace_saved'], false);
        expect(result['workspace_status'], contains('indeterminate'));
      },
    );

    test('same title creates distinct ID sibling pairs', () async {
      final workspace = Directory(p.join(root.path, 'workspace'))..createSync();
      final providerContainer = workspaceContainer(workspace);
      final runtime = providerContainer.read(artifactsChatToolRuntimeProvider);
      Future<Map> generate() async =>
          jsonDecode(
                await runtime.executeTool(
                  call(jsonEncode({'title': 'Repeated', 'markdown': 'body'})),
                  const {'generate_docx'},
                  context: ChatToolExecutionContext(
                    conversationId: 'conversation',
                    sessionKey: 'stable-key',
                    workspaceBinding: binding(providerContainer),
                  ),
                ),
              )
              as Map;

      final first = await generate();
      await Future<void>.delayed(const Duration(microseconds: 2));
      final second = await generate();

      expect(first['artifact_id'], isNot(second['artifact_id']));
      final mirrored = Directory(
        p.join(workspace.path, 'sessions', 'stable-key', 'artifacts'),
      );
      expect(mirrored.listSync().whereType<File>(), hasLength(4));
    });

    test('disallowed execution throws a permission error', () async {
      final runtime = container().read(artifactsChatToolRuntimeProvider);

      expect(
        () => runtime.executeTool(call('{}'), const {}),
        throwsA(isA<ArtifactsToolPermissionException>()),
      );
    });
  });
}

class _FailingDocxFiles extends LocalArtifactFiles {
  _FailingDocxFiles(Directory directory)
    : super(baseDirectory: () => directory);

  bool failDocx = true;

  @override
  Future<File> writeBytes(
    String artifactId,
    List<int> bytes, {
    String extension = 'md',
  }) {
    if (failDocx && extension == 'docx') {
      throw const FileSystemException('simulated DOCX failure');
    }
    return super.writeBytes(artifactId, bytes, extension: extension);
  }
}

class _FailingArtifactStore extends ArtifactStore {
  _FailingArtifactStore({this.failDelete = false});

  final bool failDelete;

  @override
  Future<void> save(artifact) async {
    await super.save(artifact);
    throw StateError('simulated metadata failure');
  }

  @override
  Future<void> delete(String id) {
    if (failDelete) throw StateError('simulated metadata delete failure');
    return super.delete(id);
  }
}

class _FailingDeleteFiles extends LocalArtifactFiles {
  _FailingDeleteFiles(Directory directory)
    : super(baseDirectory: () => directory);

  @override
  Future<void> delete(String artifactId) =>
      throw const FileSystemException('simulated file delete failure');
}

class _ArtifactSafAccess implements SafMemoryAccess, SafMemoryBinaryAccess {
  final Set<String> directories = {'root'};
  final Map<String, Uint8List> files = {};
  final Map<String, String> mimeTypes = {};
  String? unreadableSuffix;

  @override
  Future<SafMemoryDocument> createDirectory(
    String directoryUri,
    String name,
  ) async {
    final uri = '$directoryUri/$name';
    directories.add(uri);
    return SafMemoryDocument(uri: uri, name: name, isDirectory: true);
  }

  @override
  Future<List<SafMemoryDocument>> list(String directoryUri) async {
    final prefix = '$directoryUri/';
    return [
      ...directories
          .where((uri) {
            final tail = uri.startsWith(prefix)
                ? uri.substring(prefix.length)
                : '';
            return tail.isNotEmpty && !tail.contains('/');
          })
          .map(
            (uri) => SafMemoryDocument(
              uri: uri,
              name: uri.substring(prefix.length),
              isDirectory: true,
            ),
          ),
      ...files.keys
          .where((uri) {
            final tail = uri.startsWith(prefix)
                ? uri.substring(prefix.length)
                : '';
            return tail.isNotEmpty && !tail.contains('/');
          })
          .map(
            (uri) => SafMemoryDocument(
              uri: uri,
              name: uri.substring(prefix.length),
              isDirectory: false,
              mimeType: mimeTypes[uri],
            ),
          ),
    ];
  }

  @override
  Future<SafMemoryDocument> createBinary(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required String mimeType,
    required bool overwrite,
  }) async {
    final uri = '$directoryUri/$fileName';
    files[uri] = Uint8List.fromList(content);
    mimeTypes[uri] = mimeType;
    return SafMemoryDocument(
      uri: uri,
      name: fileName,
      isDirectory: false,
      mimeType: mimeType,
    );
  }

  @override
  Future<Uint8List> read(String documentUri) async {
    if (documentUri.endsWith(unreadableSuffix ?? '\u0000')) {
      throw StateError('simulated unreadable post-write');
    }
    return Uint8List.fromList(files[documentUri]!);
  }

  @override
  Future<void> writeBinaryDocument(
    String documentUri,
    Uint8List content,
  ) async {
    files[documentUri] = Uint8List.fromList(content);
  }

  @override
  Future<void> write(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required bool overwrite,
  }) async {
    files['$directoryUri/$fileName'] = Uint8List.fromList(content);
  }

  @override
  Future<void> delete(String documentUri) async {
    files.remove(documentUri);
    mimeTypes.remove(documentUri);
  }
}

String _documentXml(List<int> docxBytes) {
  final archive = ZipDecoder().decodeBytes(docxBytes);
  return utf8.decode(
    archive.files.firstWhere((file) => file.name == 'word/document.xml').content
        as List<int>,
  );
}
