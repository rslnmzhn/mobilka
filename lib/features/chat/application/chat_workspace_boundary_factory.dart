import '../../../core/workspace/workspace_binding.dart';
import '../../memory/application/session_workspace_boundary_adapter.dart';
import '../../memory/data/memory_repository.dart';
import '../../workspace/application/session_workspace_boundary.dart';

SessionWorkspaceBoundary createChatWorkspaceBoundary(
  WorkspaceBinding binding,
  String sessionKey,
  MemoryRepository repository,
) => MemorySessionWorkspaceBoundaryAdapter(
  repository,
).resolve(binding, sessionKey);
