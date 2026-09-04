import '../../../core/workspace/workspace_binding.dart';
import '../../workspace/application/session_workspace_boundary.dart';
import '../../workspace/data/native_session_workspace_boundary.dart';
import '../../workspace/data/saf_session_workspace_boundary.dart';
import '../../workspace/data/saf_workspace_models.dart';
import '../data/memory_repository.dart';
import '../data/path_memory_file_store.dart';
import '../data/saf_memory_access.dart';
import '../data/saf_memory_file_store.dart';

/// Memory-owned composition adapter from a neutral root location to a session
/// workspace boundary.
final class MemorySessionWorkspaceBoundaryAdapter {
  const MemorySessionWorkspaceBoundaryAdapter(this.repository);

  final MemoryRepository repository;

  SessionWorkspaceBoundary resolve(
    WorkspaceBinding binding,
    String sessionKey,
  ) {
    final location = binding.location;
    final memoryLocation = MemoryLocation(
      value: location.value,
      isContentUri: location.isContentUri,
    );
    final store = repository.boundaryFor(memoryLocation);
    if (store case final PathMemoryFileStore pathStore) {
      return NativeSessionWorkspaceBoundary(
        rootPath: pathStore.rootPath,
        sessionKey: sessionKey,
        revalidateAccess: binding.revalidateAccess,
      );
    }
    if (store case final SafMemoryFileStore safStore) {
      return SafSessionWorkspaceBoundary(
        directoryUri: safStore.directoryUri,
        access: _SafWorkspaceAccessAdapter(safStore.workspaceAccess),
        synchronizeRoot: safStore.rootLock.synchronized,
        sessionKey: sessionKey,
        revalidateAccess: binding.revalidateAccess,
      );
    }
    throw const WorkspaceBoundaryException('workspace_unsupported');
  }
}

final class _SafWorkspaceAccessAdapter implements WorkspaceSafAccess {
  const _SafWorkspaceAccessAdapter(this.access);

  final SafMemoryAccess access;

  @override
  Future<List<WorkspaceSafDocument>> list(String directoryUri) async =>
      (await access.list(directoryUri)).map(_document).toList(growable: false);

  @override
  Future<WorkspaceSafDocument> createDirectory(
    String directoryUri,
    String name,
  ) async => _document(await access.createDirectory(directoryUri, name));

  WorkspaceSafDocument _document(SafMemoryDocument value) =>
      WorkspaceSafDocument(
        uri: value.uri,
        name: value.name,
        isDirectory: value.isDirectory,
        mimeType: value.mimeType,
        size: value.size,
      );
}
