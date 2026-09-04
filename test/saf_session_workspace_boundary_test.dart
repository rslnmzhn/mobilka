import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:mobilka/features/workspace/application/session_workspace_boundary.dart';
import 'package:mobilka/features/workspace/data/saf_session_workspace_boundary.dart';
import 'support/saf_session_workspace_fakes.dart';
import 'package:mobilka/features/workspace/domain/session_workspace_path.dart';
import 'package:mobilka/features/workspace/domain/workspace_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('SafSessionWorkspaceBoundary', () {
    late FakeWorkspaceSaf access;
    late SafSessionWorkspaceBoundary boundary;
    var grantValid = true;
    var validations = 0;
    const channel = MethodChannel(SafSessionWorkspaceBoundary.channelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      access = FakeWorkspaceSaf()..seedWorkspace();
      grantValid = true;
      validations = 0;
      boundary = SafSessionWorkspaceBoundary(
        directoryUri: FakeWorkspaceSaf.root,
        access: WorkspaceSafTestAdapter(access),
        synchronizeRoot: <T>(action) => action(),
        sessionKey: 'session',
        revalidateAccess: () async {
          validations++;
          if (!grantValid) throw StateError('revoked');
        },
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'rootIdentity') return 'root-id';
        if (call.method == 'listDocuments') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          final path = args['path']! as String;
          final uri = path.isEmpty
              ? FakeWorkspaceSaf.session
              : '${FakeWorkspaceSaf.session}/$path';
          return access.children[uri]!
              .map(
                (document) => {
                  'uri': document.uri,
                  'documentId': 'doc:${document.uri}',
                  'name': document.name,
                  'isDirectory': document.isDirectory,
                  'mimeType': document.mimeType,
                  'size': document.size,
                },
              )
              .toList();
        }
        if (call.method != 'validateDocument' &&
            call.method != 'readDocument') {
          return null;
        }
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        final uri = args['documentUri']! as String;
        final document = access.document(uri)!;
        final bytes = access.bytes[uri];
        return {
          'documentId': 'doc:$uri',
          'size': document.isDirectory ? 0 : bytes!.length,
          'sha256': document.isDirectory ? null : workspaceHash(bytes!),
          'type': document.isDirectory ? 'directory' : 'file',
          if (call.method == 'readDocument') 'bytes': bytes,
        };
      });
    });

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('lists binary metadata without reading or decoding bodies', () async {
      access.file(FakeWorkspaceSaf.session, 'notes.txt', utf8.encode('hello'));
      access.file(
        FakeWorkspaceSaf.session,
        'report.docx',
        [0x50, 0x4b, 0, 0xff],
        mime:
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );

      final entries = await boundary.list(
        SessionWorkspacePath.parse('', allowRoot: true),
        recursive: false,
      );

      expect(entries.map((entry) => (entry.path, entry.size)), [
        ('notes.txt', 5),
        ('report.docx', 4),
      ]);
      expect(access.readCalls, 0);
      expect(entries.every((entry) => entry.sha256 == null), isTrue);
    });

    test('metadata requires native bounded hash result', () async {
      access.file(FakeWorkspaceSaf.session, 'notes.txt', utf8.encode('hello'));
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'rootIdentity') return 'root-id';
        if (call.method == 'validateDocument') return null;
        return null;
      });

      await expectLater(
        boundary.metadata(SessionWorkspacePath.parse('notes.txt')),
        _boundaryError('metadata_changed'),
      );
    });

    test('tolerates fixed-length provider lists', () async {
      access.fixedLists = true;
      access.file(FakeWorkspaceSaf.session, 'b.txt', utf8.encode('b'));
      access.file(FakeWorkspaceSaf.session, 'a.txt', utf8.encode('a'));

      final entries = await boundary.list(
        SessionWorkspacePath.parse('', allowRoot: true),
        recursive: false,
      );

      expect(entries.map((entry) => entry.path), ['a.txt', 'b.txt']);
    });

    test(
      'preserves unknown regular-file size in metadata-only lists',
      () async {
        access.file(
          FakeWorkspaceSaf.session,
          'cloud.txt',
          utf8.encode('cloud'),
        );
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'rootIdentity') return 'root-id';
          if (call.method == 'listDocuments') {
            return [
              {
                'uri': '${FakeWorkspaceSaf.session}/cloud',
                'documentId': 'cloud-id',
                'name': 'cloud.txt',
                'isDirectory': false,
                'mimeType': 'text/plain',
                'size': null,
              },
              {
                'uri': '${FakeWorkspaceSaf.session}/folder',
                'documentId': 'folder-id',
                'name': 'folder',
                'isDirectory': true,
                'mimeType': 'vnd.android.document/directory',
                'size': null,
              },
            ];
          }
          return null;
        });

        final entries = await boundary.list(
          SessionWorkspacePath.parse('', allowRoot: true),
          recursive: false,
        );

        expect(entries.map((entry) => (entry.path, entry.size)), [
          ('cloud.txt', null),
          ('folder', 0),
        ]);
      },
    );

    test('fails on duplicate names and a file used as a parent', () async {
      access.file(FakeWorkspaceSaf.session, 'same.txt', utf8.encode('a'));
      access.duplicate(FakeWorkspaceSaf.session, 'same.txt', utf8.encode('b'));
      await expectLater(
        boundary.metadata(SessionWorkspacePath.parse('same.txt')),
        _boundaryError('ambiguous_child'),
      );

      access = FakeWorkspaceSaf()..seedWorkspace();
      access.file(
        FakeWorkspaceSaf.session,
        'folder',
        utf8.encode('not a directory'),
      );
      boundary = SafSessionWorkspaceBoundary(
        directoryUri: FakeWorkspaceSaf.root,
        access: WorkspaceSafTestAdapter(access),
        synchronizeRoot: <T>(action) => action(),
        sessionKey: 'session',
        revalidateAccess: () async {},
      );
      await expectLater(
        boundary.metadata(SessionWorkspacePath.parse('folder/file.txt')),
        _boundaryError('wrong_type'),
      );
    });

    test(
      'rejects revoked, read-only, and write-only grants before I/O',
      () async {
        for (final state in ['revoked', 'read-only', 'write-only']) {
          var calls = 0;
          final guarded = SafSessionWorkspaceBoundary(
            directoryUri: FakeWorkspaceSaf.root,
            access: WorkspaceSafTestAdapter(access),
            synchronizeRoot: <T>(action) => action(),
            sessionKey: 'session',
            revalidateAccess: () async {
              calls++;
              throw StateError(state);
            },
          );
          await expectLater(
            guarded.list(
              SessionWorkspacePath.parse('', allowRoot: true),
              recursive: false,
            ),
            _boundaryError('workspace_grant_invalid'),
          );
          expect(calls, 1);
        }
        expect(access.listCalls, 0);
      },
    );

    test('revalidates immediately before each operation', () async {
      access.file(FakeWorkspaceSaf.session, 'a.txt', utf8.encode('a'));
      await boundary.metadata(SessionWorkspacePath.parse('a.txt'));
      grantValid = false;

      await expectLater(
        boundary.read(
          SessionWorkspacePath.parse('a.txt'),
          offset: 0,
          maxBytes: 1,
        ),
        _boundaryError('workspace_grant_invalid'),
      );
      expect(validations, 4);
    });

    test('reads strict UTF-8 chunks and rejects binary text', () async {
      access.file(FakeWorkspaceSaf.session, 'text.txt', utf8.encode('aéz'));
      final result = await boundary.read(
        SessionWorkspacePath.parse('text.txt'),
        offset: 1,
        maxBytes: 2,
      );
      expect(result.content, 'é');
      expect(result.sha256, workspaceHash(utf8.encode('aéz')));
      expect(result.nextOffset, 3);

      access.file(FakeWorkspaceSaf.session, 'binary.bin', [0xff, 0xfe]);
      await expectLater(
        boundary.read(
          SessionWorkspacePath.parse('binary.bin'),
          offset: 0,
          maxBytes: 2,
        ),
        _boundaryError('unsupported_text'),
      );
    });
  });
}

Matcher _boundaryError(String code) => throwsA(
  isA<WorkspaceBoundaryException>().having((error) => error.code, 'code', code),
);
