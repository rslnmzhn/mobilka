import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../artifacts/application/artifacts_controller.dart';
import '../../artifacts/data/artifact_store.dart';
import '../../chat/application/chat_controller.dart';
import '../../../core/storage/app_boxes.dart';

typedef ExportFileSaver = Future<String?> Function(String suggestedName);

/// Snapshot of every locally stored conversation and artifact.
Map<String, dynamic> collectExportData() => {
  'exportedAt': DateTime.now().toUtc().toIso8601String(),
  'conversations': conversationsBox.values.toList(growable: false),
  'artifacts': artifactsBox.values.toList(growable: false),
};

/// Removes artifact-generated files, then wipes conversations/artifacts
/// records. Memory `.md` files are intentionally untouched (user-owned).
Future<void> deleteAllLocalData(
  Future<void> Function(String artifactId) deleteArtifactFiles,
) async {
  for (final id in artifactsBox.keys.toList(growable: false)) {
    await deleteArtifactFiles(id.toString());
  }
  await conversationsBox.clear();
  await artifactsBox.clear();
}

/// Privacy disclosures plus export/delete controls for locally stored data
/// (roadmap item 55). Memory `.md` files are user-owned and intentionally not
/// touched by the delete action.
class UserDataSection extends ConsumerStatefulWidget {
  const UserDataSection({super.key, this.saveExportFile});

  /// Injectable for tests; defaults to the system save dialog.
  final ExportFileSaver? saveExportFile;

  @override
  ConsumerState<UserDataSection> createState() => _UserDataSectionState();
}

class _UserDataSectionState extends ConsumerState<UserDataSection> {
  var _busy = false;

  Map<String, dynamic> _collectExport() => collectExportData();

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final saver =
          widget.saveExportFile ??
          (String suggested) async {
            final location = await getSaveLocation(suggestedName: suggested);
            return location?.path;
          };
      final path = await saver('mobilka-export.json');
      if (path == null) return;
      await File(path).writeAsString(
        const JsonEncoder.withIndent('  ').convert(_collectExport()),
        flush: true,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('settings.exportDone'.tr())));
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('settings.deleteAllTitle'.tr()),
        content: Text('settings.deleteAllBody'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text('common.cancel'.tr()),
          ),
          FilledButton(
            key: const Key('confirm-delete-all-data'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('settings.deleteAll'.tr()),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await deleteAllLocalData(
        (id) => ref.read(localArtifactFilesProvider).delete(id),
      );
      ref.invalidate(chatControllerProvider);
      ref.invalidate(artifactsControllerProvider);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('settings.deleteAllDone'.tr())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'settings.dataTitle'.tr(),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text('settings.privacyDisclosure'.tr()),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('export-all-data'),
                onPressed: _busy ? null : _export,
                icon: const Icon(Icons.download_outlined),
                label: Text('settings.exportAll'.tr()),
              ),
              OutlinedButton.icon(
                key: const Key('delete-all-data'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: _busy ? null : _deleteAll,
                icon: const Icon(Icons.delete_forever_outlined),
                label: Text('settings.deleteAll'.tr()),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
