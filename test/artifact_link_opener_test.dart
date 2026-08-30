import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mobilka/features/artifacts/application/artifact_link_opener.dart';
import 'package:mobilka/features/artifacts/data/artifact_store.dart';
import 'package:mobilka/features/artifacts/data/local_artifact_files.dart';
import 'package:mobilka/features/artifacts/domain/artifact.dart';
import 'package:mobilka/features/artifacts/domain/artifact_link.dart';
import 'package:mobilka/features/chat/data/conversation_store.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory filesDir;
  late LocalArtifactFiles files;
  late ArtifactStore store;
  late ConversationStore conversations;
  late List<String> opened;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('artifact-opener');
    filesDir = Directory(p.join(root.path, 'artifacts'))..createSync();
    Hive.init(p.join(root.path, 'hive'));
    await Hive.openBox<dynamic>('artifacts');
    await Hive.openBox<dynamic>('conversations');
    files = LocalArtifactFiles(baseDirectory: () => filesDir);
    store = ArtifactStore();
    conversations = ConversationStore();
    opened = [];
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk('artifacts');
    await Hive.deleteBoxFromDisk('conversations');
    await Hive.close();
    await root.delete(recursive: true);
  });

  ArtifactLinkOpener opener({bool throwNative = false}) => ArtifactLinkOpener(
    store: store,
    conversations: conversations,
    files: files,
    nativeOpen: (path) async {
      if (throwNative) throw StateError('private $path');
      opened.add(path);
    },
  );

  Artifact artifact({String? owner = 'conversation', bool hash = true}) {
    const content = 'source';
    return Artifact(
      id: '1-artifact',
      title: 'Report',
      content: content,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      conversationId: owner,
      docxSourceSha256: hash
          ? sha256.convert(utf8.encode(content)).toString()
          : null,
    );
  }

  Future<void> seed(Artifact artifact, {bool docx = true}) async {
    await store.save(artifact);
    await files.write(artifact.id, artifact.content);
    if (docx) await files.writeBytes(artifact.id, [1], extension: 'docx');
    if (artifact.conversationId != null) {
      await conversations.save(
        Conversation(
          id: artifact.conversationId!,
          title: 'Chat',
          modelId: 'model',
          sessionKey: 'session',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          messages: const [],
        ),
      );
    }
  }

  ArtifactLink link(ArtifactRepresentation representation) =>
      ArtifactLink(artifactId: '1-artifact', representation: representation);

  test('chat and session require current exact owner', () async {
    await seed(artifact());
    expect(
      await opener().open(
        link(ArtifactRepresentation.md),
        scope: ArtifactOpenScope.chat,
        conversationId: 'conversation',
      ),
      ArtifactLinkOpenResult.opened,
    );
    expect(
      await opener().open(
        link(ArtifactRepresentation.md),
        scope: ArtifactOpenScope.session,
        conversationId: 'other',
      ),
      ArtifactLinkOpenResult.wrongConversation,
    );
    await conversations.delete('conversation');
    expect(
      await opener().open(
        link(ArtifactRepresentation.md),
        scope: ArtifactOpenScope.chat,
        conversationId: 'conversation',
      ),
      ArtifactLinkOpenResult.unavailable,
    );
  });

  test('catalog permits legacy while chat rejects it', () async {
    await seed(artifact(owner: null));
    expect(
      await opener().open(
        link(ArtifactRepresentation.md),
        scope: ArtifactOpenScope.catalog,
      ),
      ArtifactLinkOpenResult.opened,
    );
    expect(
      await opener().open(
        link(ArtifactRepresentation.md),
        scope: ArtifactOpenScope.chat,
        conversationId: 'conversation',
      ),
      ArtifactLinkOpenResult.wrongConversation,
    );
  });

  test(
    'DOCX requires hash matching actual Markdown and never falls back',
    () async {
      await seed(artifact(hash: false));
      expect(
        await opener().open(
          link(ArtifactRepresentation.docx),
          scope: ArtifactOpenScope.catalog,
        ),
        ArtifactLinkOpenResult.representationUnavailable,
      );
      await store.save(artifact());
      await files.write('1-artifact', 'changed');
      expect(
        await opener().open(
          link(ArtifactRepresentation.docx),
          scope: ArtifactOpenScope.catalog,
        ),
        ArtifactLinkOpenResult.representationUnavailable,
      );
      await files.deleteRepresentation('1-artifact', extension: 'docx');
      expect(
        await opener().open(
          link(ArtifactRepresentation.docx),
          scope: ArtifactOpenScope.catalog,
        ),
        ArtifactLinkOpenResult.representationUnavailable,
      );
      expect(opened, isEmpty);
    },
  );

  test(
    'corrupt metadata, directory, symlink, and native failure are safe',
    () async {
      await Hive.box<dynamic>('artifacts').put('1-artifact', {'id': 'other'});
      expect(
        await opener().open(
          link(ArtifactRepresentation.md),
          scope: ArtifactOpenScope.catalog,
        ),
        ArtifactLinkOpenResult.unavailable,
      );
      await seed(artifact());
      await File(p.join(filesDir.path, '1-artifact.md')).delete();
      await Directory(p.join(filesDir.path, '1-artifact.md')).create();
      expect(
        await opener().open(
          link(ArtifactRepresentation.md),
          scope: ArtifactOpenScope.catalog,
        ),
        ArtifactLinkOpenResult.representationUnavailable,
      );
      await Directory(p.join(filesDir.path, '1-artifact.md')).delete();
      await files.write('1-artifact', 'source');
      expect(
        await opener(throwNative: true).open(
          link(ArtifactRepresentation.md),
          scope: ArtifactOpenScope.catalog,
        ),
        ArtifactLinkOpenResult.nativeOpenFailed,
      );
    },
  );

  test(
    'store catalog ignores corrupt and key-payload mismatch entries',
    () async {
      await store.save(artifact());
      await Hive.box<dynamic>('artifacts').put('bad', {'id': 'other'});
      await Hive.box<dynamic>('artifacts').put('broken', {'id': 'broken'});
      expect(store.loadAll().map((item) => item.id), ['1-artifact']);
    },
  );
}
