import '../domain/artifact.dart';

enum ArtifactOwnershipFilter { all, owned, unowned }

enum ArtifactTypeFilter { all, markdown, docx }

enum ArtifactSort { newest, oldest, updated, name }

class ArtifactRepresentations {
  const ArtifactRepresentations({this.markdownBytes, this.docxBytes});

  final int? markdownBytes;
  final int? docxBytes;
  bool get hasMarkdown => markdownBytes != null;
  bool get hasDocx => docxBytes != null;
}

enum ArtifactOwnerKind { unowned, resolved, unavailable }

({ArtifactOwnerKind kind, String? title, String? sessionKey}) artifactOwner(
  Artifact artifact,
  Map<String, String> conversationTitles,
) {
  final ownerId = artifact.conversationId;
  if (ownerId == null) {
    return (kind: ArtifactOwnerKind.unowned, title: null, sessionKey: null);
  }
  final title = conversationTitles[ownerId];
  return (
    kind: title == null
        ? ArtifactOwnerKind.unavailable
        : ArtifactOwnerKind.resolved,
    title: title,
    sessionKey: artifact.sessionKey,
  );
}

List<Artifact> filterAndSortArtifacts({
  required Iterable<Artifact> artifacts,
  required String query,
  required ArtifactOwnershipFilter ownership,
  required ArtifactTypeFilter type,
  required ArtifactSort sort,
  required Map<String, ArtifactRepresentations> representations,
  required Map<String, String> conversationTitles,
}) {
  final needle = query.trim().toLowerCase();
  final result = artifacts
      .where((artifact) {
        final owned = artifact.conversationId != null;
        if (ownership == ArtifactOwnershipFilter.owned && !owned) return false;
        if (ownership == ArtifactOwnershipFilter.unowned && owned) return false;
        final files = representations[artifact.id];
        if (type == ArtifactTypeFilter.markdown && files?.hasMarkdown != true) {
          return false;
        }
        if (type == ArtifactTypeFilter.docx && files?.hasDocx != true) {
          return false;
        }
        if (needle.isEmpty) return true;
        return [
          artifact.title,
          artifact.content,
          artifact.id,
          '${artifact.id}.md',
          artifact.sessionKey ?? '',
          conversationTitles[artifact.conversationId] ?? '',
        ].any((value) => value.toLowerCase().contains(needle));
      })
      .toList(growable: false);
  int compare(Artifact a, Artifact b) {
    final value = switch (sort) {
      ArtifactSort.newest => b.createdAt.compareTo(a.createdAt),
      ArtifactSort.oldest => a.createdAt.compareTo(b.createdAt),
      ArtifactSort.updated => b.updatedAt.compareTo(a.updatedAt),
      ArtifactSort.name => a.title.toLowerCase().compareTo(
        b.title.toLowerCase(),
      ),
    };
    return value != 0 ? value : a.id.compareTo(b.id);
  }

  return result..sort(compare);
}
