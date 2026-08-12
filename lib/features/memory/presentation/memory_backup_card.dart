import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/memory_backup_controller.dart';

class MemoryBackupCard extends ConsumerStatefulWidget {
  const MemoryBackupCard({required this.enabled, super.key});
  final bool enabled;

  @override
  ConsumerState<MemoryBackupCard> createState() => _MemoryBackupCardState();
}

class _MemoryBackupCardState extends ConsumerState<MemoryBackupCard> {
  Object? _error;
  var _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final backup = ref.watch(memoryBackupControllerProvider);
    final preview = backup.preview;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'memory.backupRestore'.tr(),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('memory.backupDescription'.tr()),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null) Text('${'common.error'.tr()}: $_error'),
            if (preview == null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const Key('memory-create-backup'),
                    onPressed: !widget.enabled || _busy
                        ? null
                        : () => _run(() async {
                            await ref
                                .read(memoryBackupControllerProvider.notifier)
                                .createBackup();
                          }),
                    icon: const Icon(Icons.archive_outlined),
                    label: Text('memory.createBackup'.tr()),
                  ),
                  OutlinedButton.icon(
                    key: const Key('memory-choose-restore'),
                    onPressed: !widget.enabled || _busy
                        ? null
                        : () => _run(() async {
                            await ref
                                .read(memoryBackupControllerProvider.notifier)
                                .chooseRestore();
                          }),
                    icon: const Icon(Icons.restore_outlined),
                    label: Text('memory.restoreBackup'.tr()),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 12),
              Text(
                'memory.restorePreview'.tr(
                  args: [
                    preview.files.length.toString(),
                    preview.totalBytes.toString(),
                  ],
                ),
                key: const Key('memory-restore-preview'),
              ),
              ...preview.files.keys.map((name) => Text(name)),
              const SizedBox(height: 12),
              FilledButton(
                key: const Key('memory-confirm-restore'),
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => ref
                            .read(memoryBackupControllerProvider.notifier)
                            .confirmRestore(),
                      ),
                child: Text('memory.confirmRestore'.tr()),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => ref
                          .read(memoryBackupControllerProvider.notifier)
                          .cancelRestore(),
                child: Text('common.cancel'.tr()),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
