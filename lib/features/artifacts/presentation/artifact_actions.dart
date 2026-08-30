import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/artifacts_controller.dart';
import '../application/artifact_link_opener.dart';
import '../data/artifact_share_bridge.dart';
import '../domain/artifact.dart';
import '../domain/artifact_link.dart';
import 'document_editor_sheet.dart';
import 'artifact_feedback.dart';

Future<void> openArtifactEditor(
  BuildContext context,
  WidgetRef ref,
  Artifact artifact,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => DocumentEditorSheet(
      artifact: artifact,
      onSave: (title, content) => ref
          .read(artifactsControllerProvider.notifier)
          .update(artifact, title: title, content: content),
      onOpen: () async {
        final result = await ref
            .read(artifactLinkOpenerProvider)
            .open(
              ArtifactLink(
                artifactId: artifact.id,
                representation: ArtifactRepresentation.md,
              ),
              scope: ArtifactOpenScope.catalog,
            );
        if (context.mounted) showArtifactOpenResult(context, result);
      },
      onExportDocx: () => _safeExport(context, ref, artifact),
    ),
  );
}

Future<void> _safeExport(
  BuildContext context,
  WidgetRef ref,
  Artifact artifact,
) async {
  try {
    final file = await ref
        .read(artifactsControllerProvider.notifier)
        .exportDocx(artifact);
    await ref.read(artifactShareBridgeProvider)(file.path, mimeType: docxMime);
  } on Object {
    if (context.mounted) {
      showArtifactFeedback(context, 'artifacts.exportFailed');
    }
  }
}

Future<void> shareArtifact(WidgetRef ref, Artifact artifact) async {
  final path = await ref
      .read(artifactsControllerProvider.notifier)
      .shareablePath(artifact);
  await ref.read(artifactShareBridgeProvider)(path);
}

Future<void> safeShareArtifact(
  BuildContext context,
  WidgetRef ref,
  Artifact artifact,
) async {
  try {
    await shareArtifact(ref, artifact);
  } on Object {
    if (context.mounted) {
      showArtifactFeedback(context, 'artifacts.shareFailed');
    }
  }
}

Future<void> confirmDeleteArtifact(
  BuildContext context,
  WidgetRef ref,
  Artifact artifact,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      content: Text('artifacts.confirmDelete'.tr()),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('common.cancel'.tr()),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text('chat.delete'.tr()),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await ref.read(artifactsControllerProvider.notifier).delete(artifact);
  }
}
