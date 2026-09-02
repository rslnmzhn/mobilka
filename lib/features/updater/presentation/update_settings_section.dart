import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/workbench_widgets.dart';
import '../application/update_controller.dart';

class UpdateSettingsSection extends ConsumerWidget {
  const UpdateSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateControllerProvider);
    final busy =
        state.status == UpdateStatus.checking ||
        state.status == UpdateStatus.downloading ||
        state.status == UpdateStatus.applying;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const WorkbenchSectionLabel(
          label: 'Application updates',
          icon: Icons.system_update_alt,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _description(state),
                  key: const Key('update-status'),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (state.message != null || state.messageKey != null) ...[
                  const SizedBox(height: 8),
                  SelectableText(state.messageKey?.tr() ?? state.message!),
                ],
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    key: const Key('update-action'),
                    onPressed: busy
                        ? null
                        : state.status == UpdateStatus.permissionRequired
                        ? () => ref
                              .read(updateControllerProvider.notifier)
                              .retryInstall()
                        : state.staged != null
                        ? () => ref
                              .read(updateControllerProvider.notifier)
                              .retryInstall()
                        : state.status == UpdateStatus.available
                        ? () => ref
                              .read(updateControllerProvider.notifier)
                              .downloadAndApply()
                        : () => ref
                              .read(updateControllerProvider.notifier)
                              .check(),
                    icon: busy
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            state.status == UpdateStatus.available
                                ? Icons.download_outlined
                                : Icons.refresh,
                          ),
                    label: Text(
                      state.status == UpdateStatus.permissionRequired ||
                              state.staged != null
                          ? 'Install again'
                          : state.status == UpdateStatus.available
                          ? 'Download and install'
                          : 'Check for updates',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _description(UpdateState state) => switch (state.status) {
    UpdateStatus.idle => 'Updates are verified before installation.',
    UpdateStatus.checking => 'Checking the latest signed release...',
    UpdateStatus.upToDate => 'mobilka ${state.currentVersion} is up to date.',
    UpdateStatus.available =>
      'mobilka ${state.release!.version} is available (installed: ${state.currentVersion}).',
    UpdateStatus.downloading => 'Downloading and verifying the installer...',
    UpdateStatus.downloaded => 'The verified installer is ready.',
    UpdateStatus.permissionRequired =>
      'Android installation permission is required.',
    UpdateStatus.applying => 'Starting the verified installer...',
    UpdateStatus.failed => 'The update could not be completed.',
  };
}
