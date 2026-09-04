import 'dart:io';

import 'package:synchronized/synchronized.dart';

final class WorkspaceRootLocks {
  const WorkspaceRootLocks._();

  static final Map<String, Lock> _locks = {};

  static Lock forPath(String path) =>
      _locks.putIfAbsent(_pathKey(path), Lock.new);

  static Lock forSaf(String uri) => _locks.putIfAbsent('saf:$uri', Lock.new);

  static String _pathKey(String path) {
    final clean = Directory(path).absolute.uri
        .normalizePath()
        .toFilePath()
        .replaceAll(RegExp(r'[\\/]+$'), '');
    return 'path:${Platform.isWindows ? clean.toLowerCase() : clean}';
  }
}
