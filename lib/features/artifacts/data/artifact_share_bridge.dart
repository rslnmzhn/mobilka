import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
// share_plus deprecates Share.shareXFiles in favor of SharePlus.instance;
// the pinned Riverpod stack still resolves the deprecated API surface, so
// suppress until a coordinated package migration.
// ignore: deprecated_member_use
import 'package:share_plus/share_plus.dart';

part 'artifact_share_bridge.g.dart';

const docxMime =
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

typedef ArtifactShare =
    Future<void> Function(String filePath, {String? mimeType});

@Riverpod(keepAlive: true)
ArtifactShare artifactShareBridge(Ref ref) => (filePath, {mimeType}) async {
  // ignore: deprecated_member_use
  await Share.shareXFiles([XFile(filePath, mimeType: mimeType)]);
};
