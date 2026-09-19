import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../chat/application/chat_workspace_boundary_factory.dart';
import '../../memory/application/workspace_paths.dart';
import '../../memory/data/memory_repository.dart';
import '../../workspace/application/session_workspace_boundary.dart';
import '../../workspace/domain/session_workspace_path.dart';
import '../../workspace/domain/workspace_models.dart';
import '../data/artifact_share_bridge.dart';
import '../data/session_folder_open_bridge.dart';

/// Resolves the current saved SAF location at click time, not a global catalog.
final sessionFolderOpenerProvider = Provider<Future<bool> Function(String)>((
  ref,
) {
  return (sessionKey) async {
    try {
      final location = ref.read(memoryRepositoryProvider).savedLocation();
      if (location == null || !location.isContentUri) return false;
      return await const SessionFolderOpenBridge().open(
        treeUri: location.value,
        sessionKey: sessionKey,
      );
    } catch (_) {
      return false;
    }
  };
});

/// Provides the list of files stored in the physical session workspace
/// under `sessions/<sessionKey>/`.
final sessionWorkspaceFilesProvider = FutureProvider.autoDispose
    .family<List<WorkspaceEntry>, String>((ref, sessionKey) async {
      if (sessionKey.isEmpty) return const [];
      try {
        final memoryRepo = ref.watch(memoryRepositoryProvider);
        final location = memoryRepo.savedLocation();
        if (location == null) return const [];
        final binding = WorkspaceStore(repository: memoryRepo).captureBinding();
        if (binding == null) return const [];
        final boundary = createChatWorkspaceBoundary(
          binding,
          sessionKey,
          memoryRepo,
        );
        final entries = await boundary.list(
          SessionWorkspacePath.parse(''),
          recursive: true,
        );
        return entries.where((e) {
          if (e.type != WorkspaceEntryType.file) return false;
          final name = e.path.split('/').last;
          return !name.startsWith('.') && name != 'session.md';
        }).toList();
      } catch (_) {
        return const [];
      }
    });

/// Reads text content of a session workspace file.
Future<String?> readSessionWorkspaceFile(
  MemoryRepository memoryRepo,
  String sessionKey,
  String relativePath,
) async {
  final location = memoryRepo.savedLocation();
  if (location == null) return null;
  final binding = WorkspaceStore(repository: memoryRepo).captureBinding();
  if (binding == null) return null;
  try {
    final boundary = createChatWorkspaceBoundary(
      binding,
      sessionKey,
      memoryRepo,
    );
    final result = await boundary.read(
      SessionWorkspacePath.parse(relativePath),
      offset: 0,
      maxBytes: 1024 * 1024,
    );
    return result.content;
  } catch (_) {
    return null;
  }
}

/// Copies a session workspace file to share cache and shares it via [artifactShareBridgeProvider].
Future<void> shareSessionWorkspaceFile(
  WidgetRef ref,
  String sessionKey,
  String relativePath,
) async {
  final memoryRepo = ref.read(memoryRepositoryProvider);
  final location = memoryRepo.savedLocation();
  if (location == null) return;
  final binding = WorkspaceStore(repository: memoryRepo).captureBinding();
  if (binding == null) return;
  try {
    final boundary = createChatWorkspaceBoundary(
      binding,
      sessionKey,
      memoryRepo,
    );
    final cacheDir = await getTemporaryDirectory();
    final fileName = relativePath.split('/').last;
    final shareDir = Directory(p.join(cacheDir.path, 'share_workspace'));
    await shareDir.create(recursive: true);
    final targetFile = File(p.join(shareDir.path, fileName));

    if (boundary is BinarySessionWorkspaceBoundary) {
      final binary = await boundary.readBinary(
        SessionWorkspacePath.parse(relativePath),
        maxBytes: 20 * 1024 * 1024,
      );
      await targetFile.writeAsBytes(binary.bytes);
    } else {
      final text = await boundary.read(
        SessionWorkspacePath.parse(relativePath),
        offset: 0,
        maxBytes: 1024 * 1024,
      );
      await targetFile.writeAsString(text.content);
    }

    await ref.read(artifactShareBridgeProvider)(targetFile.path);
  } catch (_) {}
}
