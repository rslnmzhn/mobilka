import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../application/artifact_link_opener.dart';

String artifactOpenMessageKey(ArtifactLinkOpenResult result) =>
    switch (result) {
      ArtifactLinkOpenResult.invalid => 'artifacts.link.invalid',
      ArtifactLinkOpenResult.unavailable => 'artifacts.link.unavailable',
      ArtifactLinkOpenResult.wrongConversation =>
        'artifacts.link.wrongConversation',
      ArtifactLinkOpenResult.representationUnavailable =>
        'artifacts.link.representationUnavailable',
      ArtifactLinkOpenResult.nativeOpenFailed =>
        'artifacts.link.nativeOpenFailed',
      ArtifactLinkOpenResult.opened => 'artifacts.link.unavailable',
    };

void showArtifactFeedback(BuildContext context, String messageKey) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(messageKey.tr())));
}

void showArtifactOpenResult(
  BuildContext context,
  ArtifactLinkOpenResult result,
) {
  if (result != ArtifactLinkOpenResult.opened && context.mounted) {
    showArtifactFeedback(context, artifactOpenMessageKey(result));
  }
}
