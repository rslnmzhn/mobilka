import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/memory/application/session_notes_tools.dart';
import 'package:mobilka/features/memory/application/workspace_paths.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';
import 'package:saf/saf.dart';

void main() {
  test(
    'desktop workspace writes and reads session notes and artifacts',
    () async {
      final root = await Directory.systemTemp.createTemp('session-workspace-');
      addTearDown(() => root.delete(recursive: true));
      final location = MemoryLocation(value: root.path, isContentUri: false);
      final workspace = WorkspaceStore(
        repository: _Repository(location, PathMemoryFileStore(root.path)),
      );

      expect(
        await workspace.writeText(
          workspace.sessionNotes('stable-key'),
          '# Notes',
        ),
        isTrue,
      );
      expect(
        await workspace.readText(workspace.sessionNotes('stable-key')),
        '# Notes',
      );
      expect(
        await workspace.writeText(workspace.skillFile('safe-skill'), '# Skill'),
        isTrue,
      );
      expect(
        await workspace.readText(workspace.skillFile('safe-skill')),
        '# Skill',
      );
      expect(await workspace.listTextFiles(skillsFolder), ['safe-skill.md']);
      expect(
        await workspace.writeText(
          workspace.sessionArtifact('stable-key', 'result.txt'),
          'artifact',
        ),
        isTrue,
      );
      expect(
        await workspace.readText(
          workspace.sessionArtifact('stable-key', 'result.txt'),
        ),
        'artifact',
      );
    },
  );

  test(
    'fake SAF creates nested session and artifacts then lists and reads',
    () async {
      final access = _TreeSafAccess();
      const location = MemoryLocation(value: 'root', isContentUri: true);
      final workspace = WorkspaceStore(
        repository: _Repository(
          location,
          SafMemoryFileStore('root', access),
          validate: true,
        ),
      );

      await workspace.writeText(workspace.sessionNotes('stable-key'), 'notes');
      await workspace.writeText(workspace.skillFile('safe-skill'), 'skill');
      await workspace.writeText(
        workspace.sessionArtifact('stable-key', 'result.md'),
        'result',
      );

      expect(
        await workspace.readText(workspace.sessionNotes('stable-key')),
        'notes',
      );
      expect(
        await workspace.readText(workspace.skillFile('safe-skill')),
        'skill',
      );
      expect(await workspace.listTextFiles(skillsFolder), ['safe-skill.md']);
      expect(
        await workspace.readText(
          workspace.sessionArtifact('stable-key', 'result.md'),
        ),
        'result',
      );
      expect(
        access.directories,
        containsAll([
          'root/sessions',
          'root/sessions/stable-key',
          'root/sessions/stable-key/artifacts',
        ]),
      );
    },
  );

  test('fake SAF writes binary pair with exact MIME and bytes', () async {
    final access = _TreeSafAccess();
    const location = MemoryLocation(value: 'root', isContentUri: true);
    final workspace = WorkspaceStore(
      repository: _Repository(
        location,
        SafMemoryFileStore('root', access),
        validate: true,
      ),
    );
    final docx = Uint8List.fromList([0, 1, 2, 255]);

    final result = await workspace.writeArtifactPair(
      binding: workspace.captureBinding()!,
      sessionKey: 'immutable-key',
      artifactId: '123-artifact',
      markdown: '# Source',
      docxBytes: docx,
    );

    expect(result.complete, true);
    const parent = 'root/sessions/immutable-key/artifacts';
    expect(access.files['$parent/123-artifact.md'], utf8.encode('# Source'));
    expect(access.files['$parent/123-artifact.docx'], docx);
    expect(access.mimeTypes['$parent/123-artifact.md'], 'text/markdown');
    expect(
      access.mimeTypes['$parent/123-artifact.docx'],
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    );
  });

  test('SAF binary pair collision preserves existing siblings', () async {
    final access = _TreeSafAccess();
    final workspace = _safWorkspace(access);
    final binding = workspace.captureBinding()!;

    await workspace.writeArtifactPair(
      binding: binding,
      sessionKey: 'key',
      artifactId: '123-artifact',
      markdown: 'first',
      docxBytes: const [1],
    );
    final originalMarkdown = Uint8List.fromList(
      access.files.values.firstWhere((_) => true),
    );
    final creates = access.binaryCreates;
    final result = await workspace.writeArtifactPair(
      binding: binding,
      sessionKey: 'key',
      artifactId: '123-artifact',
      markdown: 'second',
      docxBytes: const [2],
    );

    expect(result.complete, false);
    expect(result.hasCollision, true);
    expect(access.binaryCreates, creates);
    expect(access.exactDocumentWrites, isEmpty);
    expect(
      access.files['root/sessions/key/artifacts/123-artifact.md'],
      originalMarkdown,
    );
  });

  for (final existing in ['markdown', 'docx', 'both']) {
    test('path pair preserves pre-existing $existing without writes', () async {
      final root = await Directory.systemTemp.createTemp('pair-collision-');
      addTearDown(() => root.delete(recursive: true));
      final parent = Directory(
        '${root.path}${Platform.pathSeparator}sessions${Platform.pathSeparator}key'
        '${Platform.pathSeparator}artifacts',
      )..createSync(recursive: true);
      final md = File('${parent.path}${Platform.pathSeparator}artifact.md');
      final docx = File('${parent.path}${Platform.pathSeparator}artifact.docx');
      if (existing != 'docx') md.writeAsBytesSync([9, 8, 7]);
      if (existing != 'markdown') docx.writeAsBytesSync([6, 5, 4]);
      var writeCalls = 0;
      final location = MemoryLocation(value: root.path, isContentUri: false);
      final workspace = WorkspaceStore(
        repository: _Repository(
          location,
          PathMemoryFileStore(
            root.path,
            hooks: PathMemoryFileStoreHooks(
              afterTemporaryCreated: (_, _) async => writeCalls++,
            ),
          ),
        ),
      );

      final result = await workspace.writeArtifactPair(
        binding: workspace.captureBinding()!,
        sessionKey: 'key',
        artifactId: 'artifact',
        markdown: 'new',
        docxBytes: const [1, 2],
      );

      expect(result.hasCollision, true);
      expect(writeCalls, 0);
      if (existing != 'docx') expect(md.readAsBytesSync(), [9, 8, 7]);
      if (existing != 'markdown') expect(docx.readAsBytesSync(), [6, 5, 4]);
      if (existing == 'markdown') expect(docx.existsSync(), false);
      if (existing == 'docx') expect(md.existsSync(), false);
    });
  }

  for (final existing in ['markdown', 'docx', 'both']) {
    test('SAF pair preserves pre-existing $existing without writes', () async {
      final access = _TreeSafAccess();
      final parent = 'root/sessions/key/artifacts';
      access.directories.addAll(['root/sessions', 'root/sessions/key', parent]);
      if (existing != 'docx') {
        access.files['$parent/artifact.md'] = Uint8List.fromList([9, 8, 7]);
        access.mimeTypes['$parent/artifact.md'] = 'text/markdown';
      }
      if (existing != 'markdown') {
        access.files['$parent/artifact.docx'] = Uint8List.fromList([6, 5, 4]);
        access.mimeTypes['$parent/artifact.docx'] =
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      }
      final workspace = _safWorkspace(access);

      final result = await workspace.writeArtifactPair(
        binding: workspace.captureBinding()!,
        sessionKey: 'key',
        artifactId: 'artifact',
        markdown: 'new',
        docxBytes: const [1, 2],
      );

      expect(result.hasCollision, true);
      expect(access.binaryCreates, 0);
      expect(access.exactDocumentWrites, isEmpty);
      if (existing != 'docx') {
        expect(access.files['$parent/artifact.md'], [9, 8, 7]);
      }
      if (existing != 'markdown') {
        expect(access.files['$parent/artifact.docx'], [6, 5, 4]);
      }
    });
  }

  test(
    'SAF duplicate existing child is indeterminate without writes',
    () async {
      final access = _TreeSafAccess()..duplicateCreated = true;
      const parent = 'root/sessions/key/artifacts';
      access.directories.addAll(['root/sessions', 'root/sessions/key', parent]);
      access.files['$parent/artifact.md'] = Uint8List.fromList([7]);
      access.mimeTypes['$parent/artifact.md'] = 'text/markdown';
      final workspace = _safWorkspace(access);

      final result = await workspace.writeArtifactPair(
        binding: workspace.captureBinding()!,
        sessionKey: 'key',
        artifactId: 'artifact',
        markdown: 'new',
        docxBytes: const [1],
      );

      expect(result.hasIndeterminate, true);
      expect(access.binaryCreates, 0);
      expect(access.exactDocumentWrites, isEmpty);
      expect(access.files['$parent/artifact.md'], [7]);
    },
  );

  for (final failure in ['duplicate', 'wrong MIME', 'identity mismatch']) {
    test('SAF binary create fails closed on $failure', () async {
      final access = _TreeSafAccess()
        ..duplicateCreated = failure == 'duplicate'
        ..wrongMime = failure == 'wrong MIME'
        ..returnedIdentityMismatch = failure == 'identity mismatch';
      final workspace = _safWorkspace(access);

      final result = await workspace.writeArtifactPair(
        binding: workspace.captureBinding()!,
        sessionKey: 'key',
        artifactId: '123-artifact',
        markdown: 'source',
        docxBytes: const [1, 2],
      );

      expect(result.complete, false);
    });
  }

  test(
    'workspace reports unconfigured, unsupported, and revoked storage',
    () async {
      final unsupported = _Repository(
        const MemoryLocation(value: 'unsupported', isContentUri: false),
        _FlatBoundary(),
      );
      await expectLater(
        WorkspaceStore(
          repository: _Repository(null, _FlatBoundary()),
        ).readText('sessions/key/session.md'),
        throwsA(isA<WorkspaceStorageException>()),
      );
      await expectLater(
        WorkspaceStore(
          repository: unsupported,
        ).writeText('sessions/key/session.md', 'x'),
        throwsA(
          isA<WorkspaceStorageException>().having(
            (error) => error.message,
            'message',
            contains('unavailable'),
          ),
        ),
      );
      await expectLater(
        WorkspaceStore(
          repository: _Repository(
            const MemoryLocation(value: 'revoked', isContentUri: true),
            _FlatBoundary(),
            revoke: true,
          ),
        ).readText('sessions/key/session.md'),
        throwsStateError,
      );
    },
  );

  test(
    'session tools return actionable write and read error envelopes',
    () async {
      final tools = SessionNotesTools(
        workspace: WorkspaceStore(
          repository: _Repository(null, _FlatBoundary()),
        ),
      );
      const context = ChatToolExecutionContext(
        conversationId: 'conversation',
        sessionKey: 'stable-key',
      );
      for (final call in const [
        ChatToolCall(
          id: 'write',
          name: 'write_session_notes',
          arguments: '{"content":"notes"}',
        ),
        ChatToolCall(id: 'read', name: 'read_session_notes', arguments: '{}'),
      ]) {
        final result =
            jsonDecode(
                  await tools.executeTool(call, {call.name}, context: context),
                )
                as Map<String, dynamic>;
        expect(result['ok'], isFalse);
        expect(
          result['error'],
          isA<String>().having(
            (value) => value.trim(),
            'actionable error',
            isNotEmpty,
          ),
        );
      }
    },
  );

  test('missing session notes returns an explicit safe error', () async {
    final root = await Directory.systemTemp.createTemp('missing-session-');
    addTearDown(() => root.delete(recursive: true));
    final tools = SessionNotesTools(
      workspace: WorkspaceStore(
        repository: _Repository(
          MemoryLocation(value: root.path, isContentUri: false),
          PathMemoryFileStore(root.path),
        ),
      ),
    );
    final result =
        jsonDecode(
              await tools.executeTool(
                const ChatToolCall(
                  id: 'read',
                  name: 'read_session_notes',
                  arguments: '{}',
                ),
                const {'read_session_notes'},
                context: const ChatToolExecutionContext(
                  conversationId: 'conversation',
                  sessionKey: 'stable-key',
                ),
              ),
            )
            as Map<String, dynamic>;
    expect(result['ok'], isFalse);
    expect(
      result['error'],
      isA<String>().having((v) => v, 'error', isNotEmpty),
    );
  });

  test(
    'session key distinguishes conversation IDs for identical title/date',
    () {
      final created = DateTime.utc(2026, 8, 27);
      final first = WorkspaceStore.sessionKey(
        createdAt: created,
        title: 'Same title',
        conversationId: 'conversation-aaa',
      );
      final second = WorkspaceStore.sessionKey(
        createdAt: created,
        title: 'Same title',
        conversationId: 'conversation-bbb',
      );
      expect(first, isNot(second));
    },
  );
}

class _Repository extends MemoryRepository {
  _Repository(
    this.location,
    this.boundary, {
    this.validate = false,
    this.revoke = false,
  }) : super(Saf());

  final MemoryLocation? location;
  final MemoryFileBoundary boundary;
  final bool validate;
  final bool revoke;

  @override
  MemoryLocation? savedLocation() => location;

  @override
  MemoryFileBoundary boundaryFor(MemoryLocation location) => boundary;

  @override
  Future<void> validateSavedLocationAccess(MemoryLocation location) async {
    if (revoke) throw StateError('Folder access was revoked; re-select it.');
    if (validate) return;
  }
}

class _FlatBoundary implements MemoryFileBoundary {
  @override
  Future<void> delete(String fileName) async {}
  @override
  Future<String> read(String fileName) async => '';
  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) => throw UnimplementedError();
  @override
  Future<void> write(String fileName, String content) async {}
}

class _TreeSafAccess implements SafMemoryAccess, SafMemoryBinaryAccess {
  final Set<String> directories = {'root'};
  final Map<String, Uint8List> files = {};
  final Map<String, String> mimeTypes = {};
  int binaryCreates = 0;
  final List<String> exactDocumentWrites = [];
  bool duplicateCreated = false;
  bool wrongMime = false;
  bool returnedIdentityMismatch = false;

  @override
  Future<SafMemoryDocument> createDirectory(
    String directoryUri,
    String name,
  ) async {
    final current = '$directoryUri/$name';
    directories.add(current);
    return SafMemoryDocument(uri: current, name: name, isDirectory: true);
  }

  @override
  Future<List<SafMemoryDocument>> list(String directoryUri) async {
    final prefix = '$directoryUri/';
    final children = <SafMemoryDocument>[];
    for (final directory in directories.where(
      (path) => path.startsWith(prefix),
    )) {
      final tail = directory.substring(prefix.length);
      if (!tail.contains('/')) {
        children.add(
          SafMemoryDocument(uri: directory, name: tail, isDirectory: true),
        );
      }
    }
    for (final uri in files.keys.where((path) => path.startsWith(prefix))) {
      final tail = uri.substring(prefix.length);
      if (!tail.contains('/')) {
        children.add(
          SafMemoryDocument(
            uri: uri,
            name: tail,
            isDirectory: false,
            mimeType: mimeTypes[uri],
          ),
        );
      }
    }
    if (duplicateCreated && children.any((item) => !item.isDirectory)) {
      final original = children.firstWhere((item) => !item.isDirectory);
      children.add(
        SafMemoryDocument(
          uri: '${original.uri}-duplicate',
          name: original.name,
          isDirectory: false,
          mimeType: original.mimeType,
        ),
      );
    }
    return children;
  }

  @override
  Future<Uint8List> read(String documentUri) async => files[documentUri]!;

  @override
  Future<void> write(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required bool overwrite,
  }) async {
    files['$directoryUri/$fileName'] = content;
  }

  @override
  Future<SafMemoryDocument> createBinary(
    String directoryUri,
    String fileName,
    Uint8List content, {
    required String mimeType,
    required bool overwrite,
  }) async {
    binaryCreates++;
    final uri = '$directoryUri/$fileName';
    files[uri] = content;
    final reportedMime = wrongMime ? 'application/octet-stream' : mimeType;
    mimeTypes[uri] = reportedMime;
    return SafMemoryDocument(
      uri: returnedIdentityMismatch ? '$uri-returned-elsewhere' : uri,
      name: fileName,
      isDirectory: false,
      mimeType: reportedMime,
    );
  }

  @override
  Future<void> writeBinaryDocument(
    String documentUri,
    Uint8List content,
  ) async {
    exactDocumentWrites.add(documentUri);
    files[documentUri] = content;
  }

  @override
  Future<void> delete(String documentUri) async => files.remove(documentUri);
}

WorkspaceStore _safWorkspace(_TreeSafAccess access) {
  const location = MemoryLocation(value: 'root', isContentUri: true);
  return WorkspaceStore(
    repository: _Repository(
      location,
      SafMemoryFileStore('root', access),
      validate: true,
    ),
  );
}
