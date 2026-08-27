import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../data/memory_file_store.dart';
import '../data/memory_repository.dart';

const skillsFolder = 'skills';
const sessionsFolder = 'sessions';

/// Resolves agent-workspace paths inside the owner-chosen storage folder:
///
/// storage-root/
///   user.md  soul.md  memory.md  personas.yaml
///   skills/skill-name.md
///   sessions/yyyy-MM-DD_title/session.md
///   sessions/yyyy-MM-DD_title/artifacts/files
///
class WorkspaceStore {
  WorkspaceStore({required this.repository});

  final MemoryRepository repository;

  WorkspaceBinding? captureBinding() {
    final location = repository.savedLocation();
    if (location == null) return null;
    final boundary = repository.boundaryFor(location);
    if (boundary is! BinarySubPathMemoryFileBoundary) return null;
    return WorkspaceBinding._(
      location,
      boundary as BinarySubPathMemoryFileBoundary,
    );
  }

  /// Returns the path-backed store for a configured location, or null when
  /// unconfigured or SAF-backed.
  Future<PathMemoryFileStore?> pathStore() async {
    final location = repository.savedLocation();
    if (location == null || location.isContentUri) return null;
    final boundary = repository.boundaryFor(location);
    if (boundary is PathMemoryFileStore) return boundary;
    return null;
  }

  /// Root of the storage folder, or null for SAF-backed locations.
  Future<String?> rootPath() async {
    final store = await pathStore();
    return store?.rootPath;
  }

  File? fileUnderRoot(String relativePath, {required String root}) {
    final normalized = relativePath.replaceAll('\\', '/');
    if (normalized.contains('..') || normalized.startsWith('/')) return null;
    return File('$root${Platform.pathSeparator}$normalized');
  }

  /// Reads a UTF-8 text file under the workspace root; null when missing.
  Future<String?> readText(String relativePath) async {
    final location = repository.savedLocation();
    if (location == null) throw const WorkspaceStorageException.unconfigured();
    await repository.validateSavedLocationAccess(location);
    final boundary = repository.boundaryFor(location);
    if (boundary is! SubPathMemoryFileBoundary) {
      throw const WorkspaceStorageException.io(
        'Workspace storage is unavailable.',
      );
    }
    return (boundary as SubPathMemoryFileBoundary).readSubPath(relativePath);
  }

  /// Writes a UTF-8 text file under the workspace root (creates folders).
  Future<bool> writeText(String relativePath, String content) async {
    final location = repository.savedLocation();
    if (location == null) throw const WorkspaceStorageException.unconfigured();
    await repository.validateSavedLocationAccess(location);
    final boundary = repository.boundaryFor(location);
    if (boundary is! SubPathMemoryFileBoundary) {
      throw const WorkspaceStorageException.io(
        'Workspace storage is unavailable.',
      );
    }
    return (boundary as SubPathMemoryFileBoundary).writeSubPath(
      relativePath,
      content,
    );
  }

  /// Lists safe regular files in a supported workspace directory.
  Future<List<String>> listTextFiles(String relativeDirectory) async {
    final location = repository.savedLocation();
    if (location == null) throw const WorkspaceStorageException.unconfigured();
    await repository.validateSavedLocationAccess(location);
    final boundary = repository.boundaryFor(location);
    if (boundary is! SubPathMemoryFileBoundary) {
      throw const WorkspaceStorageException.io(
        'Workspace storage is unavailable.',
      );
    }
    return (boundary as SubPathMemoryFileBoundary).listSubPath(
      relativeDirectory,
    );
  }

  String skillFile(String name) => '$skillsFolder/$name.md';

  String sessionFolder(String sessionKey) => '$sessionsFolder/$sessionKey';

  String sessionNotes(String sessionKey) =>
      '${sessionFolder(sessionKey)}/session.md';

  String sessionArtifact(String sessionKey, String fileName) =>
      '${sessionFolder(sessionKey)}/artifacts/$fileName';

  /// Validates the configured location once, then uses that exact immutable
  /// location/boundary for both sibling writes.
  Future<WorkspacePairWriteResult> writeArtifactPair({
    required WorkspaceBinding binding,
    required String sessionKey,
    required String artifactId,
    required String markdown,
    required List<int> docxBytes,
  }) async {
    await repository.validateSavedLocationAccess(binding._location);
    final binaryBoundary = binding._boundary;
    final basename = artifactId;
    return binaryBoundary.writeBinaryPair(
      WorkspaceBinaryFile(
        relativePath: sessionArtifact(sessionKey, '$basename.md'),
        bytes: Uint8List.fromList(utf8.encode(markdown)),
        mimeType: 'text/markdown',
        maxBytes: maxArtifactMarkdownBytes,
      ),
      WorkspaceBinaryFile(
        relativePath: sessionArtifact(sessionKey, '$basename.docx'),
        bytes: Uint8List.fromList(docxBytes),
        mimeType:
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        maxBytes: maxArtifactDocxBytes,
      ),
    );
  }

  /// `ГГГГ-ММ-ДД_название` — stable per conversation.
  static String sessionKey({
    required DateTime createdAt,
    required String title,
    required String conversationId,
  }) {
    final date =
        '${createdAt.year.toString().padLeft(4, '0')}-'
        '${createdAt.month.toString().padLeft(2, '0')}-'
        '${createdAt.day.toString().padLeft(2, '0')}';
    var sanitized = title
        .replaceAll(RegExp(r'[^\sa-zа-яё0-9]', caseSensitive: false), '_')
        .replaceAll(RegExp(r'[\s_]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (sanitized.length > 40) sanitized = sanitized.substring(0, 40);
    if (sanitized.isEmpty) sanitized = 'chat';
    final id = conversationId
        .replaceAll(RegExp(r'[^a-z0-9]', caseSensitive: false), '')
        .toLowerCase();
    if (id.isEmpty) {
      throw const FormatException('Conversation ID cannot form a session key.');
    }
    final suffix = id.length <= 10 ? id : id.substring(id.length - 10);
    return '${date}_${sanitized}_$suffix';
  }
}

/// Opaque, request-scoped authority for one workspace boundary. It is never
/// serialized into conversation state or tool output.
class WorkspaceBinding {
  const WorkspaceBinding._(this._location, this._boundary);

  /// Creates an opaque identity-only binding for coordinator lifecycle tests.
  @visibleForTesting
  const WorkspaceBinding.fakeForTest()
    : _location = const MemoryLocation(value: '', isContentUri: false),
      _boundary = const _UnavailableBinaryBoundary();

  final MemoryLocation _location;
  final BinarySubPathMemoryFileBoundary _boundary;
}

class _UnavailableBinaryBoundary implements BinarySubPathMemoryFileBoundary {
  const _UnavailableBinaryBoundary();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class WorkspaceStorageException implements Exception {
  const WorkspaceStorageException.unconfigured()
    : message = 'Choose a memory folder before using session notes.';
  const WorkspaceStorageException.io(this.message);

  final String message;
  @override
  String toString() => message;
}
