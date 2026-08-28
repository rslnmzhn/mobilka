import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/artifacts/data/local_artifact_files.dart';
import 'package:mobilka/features/artifacts/domain/artifact.dart';
import 'package:mobilka/features/artifacts/presentation/artifact_catalog.dart';
import 'package:path/path.dart' as p;

void main() {
  Artifact artifact(
    String id,
    String title, {
    String content = '',
    String? conversationId,
    String? sessionKey,
    int day = 1,
    int updatedDay = 1,
  }) => Artifact(
    id: id,
    title: title,
    content: content,
    conversationId: conversationId,
    sessionKey: sessionKey,
    createdAt: DateTime.utc(2026, 8, day),
    updatedAt: DateTime.utc(2026, 8, updatedDay),
  );

  test('searches every real catalog field and resolved owner title', () {
    final item = artifact(
      'report-artifact',
      'Quarterly report',
      content: 'needle body',
      conversationId: 'conversation',
      sessionKey: 'session-provenance',
    );
    for (final query in [
      'quarterly',
      'needle',
      'report-artifact.md',
      'session-provenance',
      'resolved chat',
    ]) {
      expect(
        filterAndSortArtifacts(
          artifacts: [item],
          query: query,
          ownership: ArtifactOwnershipFilter.all,
          type: ArtifactTypeFilter.all,
          sort: ArtifactSort.newest,
          representations: const {},
          conversationTitles: const {'conversation': 'Resolved chat'},
        ),
        [item],
      );
    }
  });

  test('ownership and actual representation filters are independent', () {
    final owned = artifact('owned', 'Owned', conversationId: 'conversation');
    final legacy = artifact('legacy', 'Legacy');
    const files = {
      'owned': ArtifactRepresentations(markdownBytes: 4),
      'legacy': ArtifactRepresentations(docxBytes: 8),
    };
    List<Artifact> select(
      ArtifactOwnershipFilter ownership,
      ArtifactTypeFilter type,
    ) => filterAndSortArtifacts(
      artifacts: [owned, legacy],
      query: '',
      ownership: ownership,
      type: type,
      sort: ArtifactSort.newest,
      representations: files,
      conversationTitles: const {},
    );

    expect(select(ArtifactOwnershipFilter.owned, ArtifactTypeFilter.markdown), [
      owned,
    ]);
    expect(select(ArtifactOwnershipFilter.unowned, ArtifactTypeFilter.docx), [
      legacy,
    ]);
    expect(
      select(ArtifactOwnershipFilter.owned, ArtifactTypeFilter.docx),
      isEmpty,
    );
  });

  test('sorts are stable with ID tie breakers', () {
    final a = artifact('a', 'Same', day: 2, updatedDay: 2);
    final b = artifact('b', 'Same', day: 1, updatedDay: 3);
    List<String> sorted(ArtifactSort sort) => filterAndSortArtifacts(
      artifacts: [b, a],
      query: '',
      ownership: ArtifactOwnershipFilter.all,
      type: ArtifactTypeFilter.all,
      sort: sort,
      representations: const {},
      conversationTitles: const {},
    ).map((item) => item.id).toList();
    expect(sorted(ArtifactSort.newest), ['a', 'b']);
    expect(sorted(ArtifactSort.oldest), ['b', 'a']);
    expect(sorted(ArtifactSort.updated), ['b', 'a']);
    expect(sorted(ArtifactSort.name), ['a', 'b']);
  });

  test('owner projection distinguishes legacy, resolved, and unavailable', () {
    expect(
      artifactOwner(artifact('legacy', 'Legacy'), const {}).kind,
      ArtifactOwnerKind.unowned,
    );
    expect(
      artifactOwner(artifact('owned', 'Owned', conversationId: 'c'), const {
        'c': 'Chat',
      }).kind,
      ArtifactOwnerKind.resolved,
    );
    final orphan = artifactOwner(
      artifact(
        'orphan',
        'Orphan',
        conversationId: 'deleted',
        sessionKey: 'session-key',
      ),
      const {},
    );
    expect(orphan.kind, ArtifactOwnerKind.unavailable);
    expect(orphan.sessionKey, 'session-key');
  });

  test('safe stats tolerate missing files and reject symlinks', () async {
    final root = await Directory.systemTemp.createTemp('artifact-stat');
    addTearDown(() => root.delete(recursive: true));
    final files = LocalArtifactFiles(baseDirectory: () => root);
    expect(await files.stat('missing', extension: 'md'), isNull);
    await files.write('regular', 'body');
    expect((await files.stat('regular', extension: 'md'))?.size, 4);

    final outside = File(p.join(root.parent.path, 'artifact-stat-outside'));
    await outside.writeAsString('secret');
    addTearDown(() async {
      if (await outside.exists()) await outside.delete();
    });
    try {
      await Link(p.join(root.path, 'linked.md')).create(outside.path);
      expect(await files.stat('linked', extension: 'md'), isNull);
    } on FileSystemException {
      // Symlink creation is not available to all Windows test users.
    }
  });
}
