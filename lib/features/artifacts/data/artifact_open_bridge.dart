import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'artifact_open_bridge.g.dart';

typedef ArtifactOpen = Future<void> Function(String filePath);

/// Opens an artifact file with the platform-native viewer: Android resolves
/// through FileProvider grants (open_filex), desktop shells use their default
/// handler for the file type.
@Riverpod(keepAlive: true)
ArtifactOpen artifactOpenBridge(Ref ref) {
  return (filePath) async {
    final result = await OpenFilex.open(filePath);
    if (result.type != ResultType.done) {
      throw StateError('Could not open file: ${result.message}');
    }
  };
}
