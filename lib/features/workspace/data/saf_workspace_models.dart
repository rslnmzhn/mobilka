import '../application/session_workspace_boundary.dart';
import '../domain/workspace_models.dart';

final class WorkspaceSafDocument {
  const WorkspaceSafDocument({
    required this.uri,
    required this.name,
    required this.isDirectory,
    this.mimeType,
    this.size,
  });

  final String uri;
  final String name;
  final bool isDirectory;
  final String? mimeType;
  final int? size;
}

abstract interface class WorkspaceSafAccess {
  Future<List<WorkspaceSafDocument>> list(String directoryUri);
  Future<WorkspaceSafDocument> createDirectory(
    String directoryUri,
    String name,
  );
}

final class ListedWorkspaceDocument {
  const ListedWorkspaceDocument({
    required this.document,
    required this.documentId,
  });

  final WorkspaceSafDocument document;
  final String documentId;
}

final class SafInspectedDocument {
  const SafInspectedDocument({
    required this.documentId,
    required this.size,
    required this.sha256,
    required this.type,
  });

  final String documentId;
  final int size;
  final String? sha256;
  final WorkspaceEntryType type;

  factory SafInspectedDocument.fromJson(Map<Object?, Object?> json) {
    final identity = json['documentId'];
    final size = json['size'];
    final hash = json['sha256'];
    final type = json['type'];
    if (identity is! String ||
        identity.isEmpty ||
        size is! int ||
        size < 0 ||
        (hash != null && hash is! String) ||
        type is! String) {
      throw const WorkspaceBoundaryException('invalid_native_result');
    }
    final parsedType = WorkspaceEntryType.values
        .where((candidate) => candidate.name == type)
        .firstOrNull;
    if (parsedType == null ||
        (parsedType == WorkspaceEntryType.directory &&
            (size != 0 || hash != null)) ||
        (parsedType == WorkspaceEntryType.file &&
            (hash is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)))) {
      throw const WorkspaceBoundaryException('invalid_native_result');
    }
    return SafInspectedDocument(
      documentId: identity,
      size: size,
      sha256: hash as String?,
      type: parsedType,
    );
  }
}
