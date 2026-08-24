import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_controller.dart';
import '../../../core/theme/workbench_widgets.dart';
import 'user_data_section.dart';
import '../../updater/presentation/update_settings_section.dart';
import '../application/settings_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final theme = ref.watch(themeControllerProvider);
    final diagnostics = ref.watch(diagnosticLogProvider);
    return Scaffold(
      appBar: AppBar(
        title: WorkbenchPageTitle(
          icon: Icons.tune_outlined,
          title: 'settings.title'.tr(),
          detail: 'WORKBENCH CONTROL',
        ),
      ),
      body: WorkbenchBody(
        maxWidth: 820,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            WorkbenchSectionLabel(
              label: 'settings.appearance'.tr(),
              icon: Icons.palette_outlined,
            ),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    title: Text('settings.darkMode'.tr()),
                    value: theme.mode == ThemeMode.dark,
                    onChanged: ref
                        .read(themeControllerProvider.notifier)
                        .setDarkMode,
                  ),
                  ListTile(
                    title: Text('settings.themePreset'.tr()),
                    trailing: DropdownButton<ThemePreset>(
                      value: theme.preset,
                      items: ThemePreset.values
                          .map(
                            (preset) => DropdownMenuItem(
                              value: preset,
                              child: Text(preset.label),
                            ),
                          )
                          .toList(),
                      onChanged: (preset) {
                        if (preset != null) {
                          ref
                              .read(themeControllerProvider.notifier)
                              .setPreset(preset);
                        }
                      },
                    ),
                  ),
                  ListTile(
                    title: Text('settings.language'.tr()),
                    trailing: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'en', label: Text('EN')),
                        ButtonSegment(value: 'ru', label: Text('RU')),
                      ],
                      selected: {context.locale.languageCode},
                      onSelectionChanged: (value) =>
                          context.setLocale(Locale(value.first)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            WorkbenchSectionLabel(
              label: 'settings.diagnostics'.tr(),
              icon: Icons.monitor_heart_outlined,
            ),
            Card(
              child: ExpansionTile(
                key: const Key('settings-diagnostics'),
                title: Text('settings.operationalLogs'.tr()),
                subtitle: Text(
                  'settings.operationalLogsDescription'.tr(
                    args: [diagnostics.length.toString()],
                  ),
                ),
                children: [
                  if (diagnostics.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('settings.noDiagnosticLogs'.tr()),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: diagnostics.length,
                        itemBuilder: (_, index) => Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          child: SelectableText(
                            diagnostics[index].toString(),
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                    ),
                  OverflowBar(
                    alignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: diagnostics.isEmpty
                            ? null
                            : () => ref
                                  .read(diagnosticLogProvider.notifier)
                                  .clear(),
                        child: Text('settings.clearLogs'.tr()),
                      ),
                      FilledButton.tonalIcon(
                        key: const Key('copy-diagnostic-logs'),
                        onPressed: diagnostics.isEmpty
                            ? null
                            : () async {
                                await Clipboard.setData(
                                  ClipboardData(text: diagnostics.join('\n')),
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('settings.logsCopied'.tr()),
                                    ),
                                  );
                                }
                              },
                        icon: const Icon(Icons.copy_outlined),
                        label: Text('settings.copyLogs'.tr()),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const UpdateSettingsSection(),
            const SizedBox(height: 20),
            const UserDataSection(),
            const SizedBox(height: 20),
            WorkbenchSectionLabel(
              label: 'settings.connection'.tr(),
              icon: Icons.cable_outlined,
            ),
            settings.when(
              loading: () => const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: LinearProgressIndicator(),
                ),
              ),
              error: (error, _) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('${'common.error'.tr()}: $error'),
                ),
              ),
              data: (value) => _EndpointForm(
                baseUrl: value.baseUrl,
                hasApiKey: value.hasApiKey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EndpointForm extends ConsumerStatefulWidget {
  const _EndpointForm({required this.baseUrl, required this.hasApiKey});
  final String baseUrl;
  final bool hasApiKey;

  @override
  ConsumerState<_EndpointForm> createState() => _EndpointFormState();
}

class _EndpointFormState extends ConsumerState<_EndpointForm> {
  late final TextEditingController baseUrl = TextEditingController(
    text: widget.baseUrl,
  );
  final apiKey = TextEditingController();
  bool obscure = true;

  @override
  void dispose() {
    baseUrl.dispose();
    apiKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            TextField(
              controller: baseUrl,
              decoration: InputDecoration(
                labelText: 'settings.baseUrl'.tr(),
                prefixIcon: const Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: apiKey,
              obscureText: obscure,
              decoration: InputDecoration(
                labelText: widget.hasApiKey
                    ? 'settings.replaceApiKey'.tr()
                    : 'settings.apiKey'.tr(),
                prefixIcon: const Icon(Icons.key),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => obscure = !obscure),
                  icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'settings.httpWarning'.tr(),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  await ref
                      .read(settingsControllerProvider.notifier)
                      .save(baseUrl: baseUrl.text, apiKey: apiKey.text);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('settings.saved'.tr())),
                  );
                },
                icon: const Icon(Icons.save_outlined),
                label: Text('common.save'.tr()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
