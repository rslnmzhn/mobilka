import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_controller.dart';
import '../application/settings_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final theme = ref.watch(themeControllerProvider);
    return Scaffold(
      appBar: AppBar(title: Text('settings.title'.tr())),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'settings.appearance'.tr(),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
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
          const SizedBox(height: 20),
          Text(
            'settings.connection'.tr(),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
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
