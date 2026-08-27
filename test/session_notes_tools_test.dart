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

class _TreeSafAccess implements SafMemoryAccess {
  final Set<String> directories = {'root'};
  final Map<String, Uint8List> files = {};

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
          SafMemoryDocument(uri: uri, name: tail, isDirectory: false),
        );
      }
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
  Future<void> delete(String documentUri) async => files.remove(documentUri);
}
