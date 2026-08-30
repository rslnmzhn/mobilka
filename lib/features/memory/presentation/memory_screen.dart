import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/workbench_widgets.dart';
import '../application/memory_controller.dart';
import '../application/memory_file_editor.dart';
import '../application/memory_selection_controller.dart';
import '../application/update_memory_file_service.dart';
import '../data/memory_repository.dart';
import 'memory_backup_card.dart';
import 'memory_editor_sheet.dart';

class MemoryScreen extends ConsumerWidget {
  const MemoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memory = ref.watch(memoryControllerProvider);
    final selection = ref.watch(memorySelectionControllerProvider);
    final editor = ref.watch(memoryFileEditorProvider);
    return Scaffold(
      appBar: AppBar(
        title: WorkbenchPageTitle(
          icon: Icons.folder_copy_outlined,
          title: 'memory.title'.tr(),
          detail: 'MARKDOWN VAULT',
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            children: [
              WorkbenchSectionLabel(
                label: 'memory.externalFolder'.tr(),
                icon: Icons.folder_outlined,
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'memory.externalFolder'.tr(),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text('memory.description'.tr()),
                      const SizedBox(height: 16),
                      memory.when(
                        loading: () => const LinearProgressIndicator(),
                        error: (error, _) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${'common.error'.tr()}: $error'),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              children: [
                                FilledButton(
                                  onPressed: () => ref
                                      .read(memoryControllerProvider.notifier)
                                      .retryCurrentFolder(),
                                  child: Text('common.retry'.tr()),
                                ),
                                OutlinedButton(
                                  onPressed: () => ref
                                      .read(memoryControllerProvider.notifier)
                                      .chooseFolder(),
                                  child: Text('memory.change'.tr()),
                                ),
                              ],
                            ),
                          ],
                        ),
                        data: (location) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (location != null)
                              SelectableText(location.value),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: () => ref
                                  .read(memoryControllerProvider.notifier)
                                  .chooseFolder(),
                              icon: const Icon(
                                Icons.create_new_folder_outlined,
                              ),
                              label: Text(
                                location == null
                                    ? 'memory.choose'.tr()
                                    : 'memory.change'.tr(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              WorkbenchSectionLabel(
                label: 'memory.files'.tr(),
                icon: Icons.description_outlined,
              ),
              ...MemoryRepository.templates.keys.map(
                (name) => Card(
                  child: SwitchListTile(
                    key: Key('memory-inclusion-$name'),
                    secondary: const Icon(Icons.description_outlined),
                    title: Text(name),
                    subtitle: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        key: Key('memory-edit-$name'),
                        onPressed: editor == null
                            ? null
                            : () => showModalBottomSheet<void>(
                                context: context,
                                isScrollControlled: true,
                                builder: (_) => MemoryEditorSheet(
                                  fileName: name,
                                  editor: editor,
                                ),
                              ),
                        icon: const Icon(Icons.edit_outlined),
                        label: Text('memory.openEdit'.tr()),
                      ),
                    ),
                    value: selection.contains(name),
                    onChanged: (included) async {
                      try {
                        await ref
                            .read(memorySelectionControllerProvider.notifier)
                            .setIncluded(name, included: included);
                      } on Object catch (error) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('${'common.error'.tr()}: $error'),
                          ),
                        );
                      }
                    },
                  ),
                ),
              ),
              Card(
                child: ListTile(
                  key: const Key('memory-personas-folder'),
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('personas/'),
                  subtitle: Text('memory.personasHint'.tr()),
                ),
              ),
              const SizedBox(height: 16),
              MemoryBackupCard(enabled: memory.valueOrNull != null),
            ],
          ),
        ),
      ),
    );
  }
}

class MemoryUpdateSheet extends StatefulWidget {
  const MemoryUpdateSheet({
    required this.fileName,
    required this.service,
    super.key,
  });

  final String fileName;
  final UpdateMemoryFileService service;

  @override
  State<MemoryUpdateSheet> createState() => _MemoryUpdateSheetState();
}

class _MemoryUpdateSheetState extends State<MemoryUpdateSheet> {
  final _controller = TextEditingController();
  MemoryUpdatePreview? _preview;
  Object? _error;
  var _loading = true;

  @override
  void initState() {
    super.initState();
    widget.service
        .readCurrent(widget.fileName)
        .then(
          (content) {
            if (!mounted) return;
            setState(() {
              _controller.text = content;
              _loading = false;
            });
          },
          onError: (Object error) {
            if (!mounted) return;
            setState(() {
              _error = error;
              _loading = false;
            });
          },
        );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preview = await widget.service.preparePreview(
        widget.fileName,
        _controller.text,
      );
      if (mounted) setState(() => _preview = preview);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirm() async {
    final preview = _preview!;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.service.apply(
        fileName: preview.fileName,
        proposedContent: preview.proposedContent,
        diff: preview.diff,
        confirmationToken: preview.confirmationToken,
        version: preview.version,
        createdAt: preview.createdAt,
      );
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _preview = null;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.fileName,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              if (_loading) const LinearProgressIndicator(),
              if (_error != null) Text('${'common.error'.tr()}: $_error'),
              if (preview == null) ...[
                TextField(
                  key: const Key('memory-update-content'),
                  controller: _controller,
                  minLines: 8,
                  maxLines: 18,
                  enabled: !_loading,
                  decoration: InputDecoration(
                    labelText: 'memory.proposedContent'.tr(),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _loading ? null : _prepare,
                  child: Text('memory.previewUpdate'.tr()),
                ),
              ] else ...[
                Text('memory.diffPreview'.tr()),
                const SizedBox(height: 8),
                SelectableText(
                  preview.diff,
                  key: const Key('memory-update-diff'),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  '${'memory.version'.tr()}: ${preview.version}',
                  key: const Key('memory-update-version'),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const Key('memory-update-confirm'),
                  onPressed: _loading ? null : _confirm,
                  child: Text('memory.confirmExactUpdate'.tr()),
                ),
                TextButton(
                  onPressed: _loading
                      ? null
                      : () => setState(() => _preview = null),
                  child: Text('memory.editAgain'.tr()),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
