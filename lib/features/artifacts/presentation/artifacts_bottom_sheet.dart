import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/domain/conversation.dart';
import '../../chat/domain/tool_execution.dart';
import '../application/artifacts_controller.dart';
import '../data/artifact_share_bridge.dart';
import '../domain/artifact.dart';
import 'document_editor_sheet.dart';

class ArtifactsBottomSheet extends StatelessWidget {
  const ArtifactsBottomSheet({this.conversation, super.key});

  final Conversation? conversation;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 4,
    child: FractionallySizedBox(
      heightFactor: 0.82,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'artifacts.title'.tr(),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: 'common.close'.tr(),
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(text: 'artifacts.code'.tr()),
                  Tab(text: 'artifacts.documents'.tr()),
                  Tab(text: 'artifacts.preview'.tr()),
                  Tab(text: 'artifacts.logs'.tr()),
                ],
              ),
              const Divider(height: 1),
              Expanded(
                child: TabBarView(
                  children: [
                    _EmptyArtifactTab(
                      icon: Icons.code,
                      message: 'artifacts.noCode'.tr(),
                    ),
                    const _DocumentsTab(),
                    _EmptyArtifactTab(
                      icon: Icons.preview_outlined,
                      message: 'artifacts.noPreview'.tr(),
                    ),
                    _ExecutionLogTab(conversation: conversation),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _EmptyArtifactTab extends StatelessWidget {
  const _EmptyArtifactTab({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class _DocumentsTab extends ConsumerWidget {
  const _DocumentsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artifacts = ref.watch(artifactsControllerProvider);
    if (artifacts.isEmpty) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _EmptyArtifactTab(
            icon: Icons.description_outlined,
            message: 'artifacts.noDocuments'.tr(),
          ),
          FilledButton.tonalIcon(
            key: const Key('artifact-create'),
            onPressed: () => _openEditor(context, ref, null),
            icon: const Icon(Icons.add),
            label: Text('artifacts.create'.tr()),
          ),
        ],
      );
    }
    return ListView(
      key: const Key('artifact-documents'),
      padding: const EdgeInsets.all(16),
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonalIcon(
            key: const Key('artifact-create'),
            onPressed: () => _openEditor(context, ref, null),
            icon: const Icon(Icons.add),
            label: Text('artifacts.create'.tr()),
          ),
        ),
        const SizedBox(height: 8),
        for (final artifact in artifacts)
          ListTile(
            key: Key('artifact-item-${artifact.id}'),
            shape: RoundedRectangleBorder(
              side: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            title: Text(
              artifact.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              MaterialLocalizations.of(
                context,
              ).formatCompactDate(artifact.updatedAt),
            ),
            onTap: () => _openEditor(context, ref, artifact),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: Key('artifact-share-${artifact.id}'),
                  tooltip: 'artifacts.share'.tr(),
                  onPressed: () => _share(context, ref, artifact),
                  icon: const Icon(Icons.share_outlined),
                ),
                IconButton(
                  key: Key('artifact-delete-${artifact.id}'),
                  tooltip: 'chat.delete'.tr(),
                  onPressed: () => _confirmDelete(context, ref, artifact),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
      ],
    );
  }

  void _openEditor(BuildContext context, WidgetRef ref, Artifact? artifact) {
    final controller = ref.read(artifactsControllerProvider.notifier);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => DocumentEditorSheet(
        artifact: artifact,
        onSave: (title, content) => artifact == null
            ? controller.create(title: title, content: content)
            : controller.update(artifact, title: title, content: content),
      ),
    );
  }

  Future<void> _share(
    BuildContext context,
    WidgetRef ref,
    Artifact artifact,
  ) async {
    try {
      final path = await ref
          .read(artifactsControllerProvider.notifier)
          .shareablePath(artifact);
      await ref.read(artifactShareBridgeProvider)(path);
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Artifact artifact,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('chat.delete'.tr()),
        content: Text('artifacts.confirmDelete'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text('common.cancel'.tr()),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('chat.delete'.tr()),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(artifactsControllerProvider.notifier).delete(artifact);
    }
  }
}

class _ExecutionLogTab extends StatelessWidget {
  const _ExecutionLogTab({required this.conversation});

  final Conversation? conversation;

  @override
  Widget build(BuildContext context) {
    final entries = projectToolExecutions(conversation);
    if (entries.isEmpty) {
      return _EmptyArtifactTab(
        icon: Icons.receipt_long_outlined,
        message: 'artifacts.noLogs'.tr(),
      );
    }
    return ListView.separated(
      key: const Key('artifact-execution-logs'),
      padding: const EdgeInsets.all(16),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _ExecutionLogTile(entry: entries[index]),
    );
  }
}

class _ExecutionLogTile extends StatelessWidget {
  const _ExecutionLogTile({required this.entry});

  final ToolExecution entry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = switch (entry.status) {
      ToolExecutionStatus.running => colors.primary,
      ToolExecutionStatus.completed => colors.tertiary,
      ToolExecutionStatus.failed => colors.error,
    };
    return ExpansionTile(
      key: Key('artifact-log-${entry.assistantMessageId}-${entry.callIndex}'),
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      collapsedShape: RoundedRectangleBorder(
        side: BorderSide(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      leading: Icon(switch (entry.status) {
        ToolExecutionStatus.running => Icons.pending_outlined,
        ToolExecutionStatus.completed => Icons.check_circle_outline,
        ToolExecutionStatus.failed => Icons.error_outline,
      }, color: color),
      title: Text(entry.call.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(switch (entry.status) {
        ToolExecutionStatus.running => 'chat.toolRunning'.tr(),
        ToolExecutionStatus.completed => 'chat.toolCompleted'.tr(),
        ToolExecutionStatus.failed => 'chat.toolFailed'.tr(),
      }, style: TextStyle(color: color)),
      children: [
        _LogPayload(label: 'chat.toolInput'.tr(), value: entry.call.arguments),
        if (entry.result != null) ...[
          const SizedBox(height: 8),
          _LogPayload(
            label: entry.status == ToolExecutionStatus.failed
                ? 'chat.toolError'.tr()
                : 'chat.toolOutput'.tr(),
            value: entry.error ?? entry.result!.content,
            color: entry.status == ToolExecutionStatus.failed
                ? colors.error
                : null,
          ),
        ],
      ],
    );
  }
}

class _LogPayload extends StatelessWidget {
  const _LogPayload({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 160),
          padding: const EdgeInsets.all(10),
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: SingleChildScrollView(
            child: SelectableText(
              _pretty(value),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: color,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  static String _pretty(String value) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(value));
    } on FormatException {
      return value;
    }
  }
}
