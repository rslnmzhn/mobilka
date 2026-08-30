import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';
import 'package:crypto/crypto.dart';

import '../../chat/data/conversation_store.dart';
import '../data/artifact_open_bridge.dart';
import '../data/artifact_store.dart';
import '../data/local_artifact_files.dart';
import '../domain/artifact_link.dart';

enum ArtifactOpenScope { chat, session, catalog }

enum ArtifactLinkOpenResult {
  opened,
  invalid,
  unavailable,
  wrongConversation,
  representationUnavailable,
  nativeOpenFailed,
}

typedef ArtifactLinkOpenCallback =
    Future<ArtifactLinkOpenResult> Function(
      ArtifactLink link, {
      required ArtifactOpenScope scope,
      String? conversationId,
    });

final artifactLinkOpenerProvider = Provider<ArtifactLinkOpener>((ref) {
  return ArtifactLinkOpener(
    store: ref.read(artifactStoreProvider),
    conversations: ref.read(conversationStoreProvider),
    files: ref.read(localArtifactFilesProvider),
    nativeOpen: ref.read(artifactOpenBridgeProvider),
  );
});

class ArtifactLinkOpener {
  const ArtifactLinkOpener({
    required ArtifactStore store,
    required ConversationStore conversations,
    required LocalArtifactFiles files,
    required ArtifactOpen nativeOpen,
  }) : _store = store,
       _conversations = conversations,
       _files = files,
       _nativeOpen = nativeOpen;

  final ArtifactStore _store;
  final ConversationStore _conversations;
  final LocalArtifactFiles _files;
  final ArtifactOpen _nativeOpen;

  Future<ArtifactLinkOpenResult> open(
    ArtifactLink link, {
    required ArtifactOpenScope scope,
    String? conversationId,
  }) async {
    final artifact = _store.loadById(link.artifactId);
    if (artifact == null) return ArtifactLinkOpenResult.unavailable;
    if (scope != ArtifactOpenScope.catalog) {
      if (conversationId == null || artifact.conversationId != conversationId) {
        return ArtifactLinkOpenResult.wrongConversation;
      }
      if (_conversations.loadById(conversationId) == null) {
        return ArtifactLinkOpenResult.unavailable;
      }
    }
    if (link.representation == ArtifactRepresentation.docx &&
        !await _docxIsFresh(artifact.id, artifact.docxSourceSha256)) {
      return ArtifactLinkOpenResult.representationUnavailable;
    }
    try {
      final opened = await _files.withVerifiedFileForOpen<bool>(
        artifact.id,
        extension: link.representation.name,
        callback: (path) async {
          await _nativeOpen(path);
          return true;
        },
      );
      if (opened != true) {
        return ArtifactLinkOpenResult.representationUnavailable;
      }
      return ArtifactLinkOpenResult.opened;
    } on Object {
      return ArtifactLinkOpenResult.nativeOpenFailed;
    }
  }

  Future<bool> _docxIsFresh(String id, String? expected) async {
    if (expected == null) return false;
    try {
      final digest = await _files.withVerifiedFileForOpen<String>(
        id,
        extension: 'md',
        callback: (path) async =>
            sha256.convert(await File(path).readAsBytes()).toString(),
      );
      return digest == expected;
    } on Object {
      return false;
    }
  }
}
