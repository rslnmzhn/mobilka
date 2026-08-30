import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/workbench_widgets.dart';
import '../application/searxng_settings_controller.dart';
import '../application/web_search_policy.dart';
import '../domain/searxng_search_settings.dart';

class SearxngSettingsSection extends ConsumerWidget {
  const SearxngSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(searxngSettingsControllerProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WorkbenchSectionLabel(
          label: 'settings.webSearch'.tr(),
          icon: Icons.travel_explore_outlined,
        ),
        state.when(
          loading: () => const Card(child: LinearProgressIndicator()),
          error: (_, _) => Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('settings.searchInvalid'.tr()),
            ),
          ),
          data: (value) => _SearchForm(key: ValueKey(value), initial: value),
        ),
      ],
    );
  }
}

class _SearchForm extends ConsumerStatefulWidget {
  const _SearchForm({super.key, required this.initial});
  final SearxngSearchSettings initial;
  @override
  ConsumerState<_SearchForm> createState() => _SearchFormState();
}

class _SearchFormState extends ConsumerState<_SearchForm> {
  late bool enabled = widget.initial.enabled;
  late String locale = widget.initial.locale;
  late String range = widget.initial.timeRange;
  late int maximum = widget.initial.maxResults;
  late bool acknowledged = widget.initial.httpAcknowledged;
  late final endpoint = TextEditingController(text: widget.initial.baseUrl);
  final secret = TextEditingController();
  bool saving = false;
  bool get isHttp => Uri.tryParse(endpoint.text.trim())?.scheme == 'http';

  @override
  void dispose() {
    endpoint.dispose();
    secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('settings.searchEnabled'.tr()),
            value: enabled,
            onChanged: (value) => setState(() => enabled = value),
          ),
          Text(
            'settings.searchPrivacy'.tr(),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('searxng-base-url'),
            controller: endpoint,
            onChanged: (_) => setState(() {
              acknowledged =
                  endpoint.text.trim() == widget.initial.httpAcknowledgedUrl;
            }),
            decoration: InputDecoration(
              labelText: 'settings.searchBaseUrl'.tr(),
              prefixIcon: const Icon(Icons.link),
            ),
          ),
          if (isHttp) ...[
            const SizedBox(height: 8),
            Text(
              'settings.searchHttpWarning'.tr(),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('settings.searchHttpAcknowledge'.tr()),
              value: acknowledged,
              onChanged: (value) =>
                  setState(() => acknowledged = value ?? false),
            ),
          ] else ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('searxng-secret'),
              controller: secret,
              obscureText: true,
              decoration: InputDecoration(
                labelText: widget.initial.hasSecret
                    ? 'settings.searchReplaceSecret'.tr()
                    : 'settings.searchSecret'.tr(),
                prefixIcon: const Icon(Icons.key),
              ),
            ),
            if (widget.initial.hasSecret)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => ref
                      .read(searxngSettingsControllerProvider.notifier)
                      .clearSecret(),
                  child: Text('settings.searchClearSecret'.tr()),
                ),
              ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<String>(
                  initialValue: locale,
                  decoration: InputDecoration(
                    labelText: 'settings.searchLocale'.tr(),
                  ),
                  items: const ['en', 'ru', 'en-US', 'ru-RU']
                      .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                      .toList(),
                  onChanged: (v) => locale = v ?? locale,
                ),
              ),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<String>(
                  initialValue: range,
                  decoration: InputDecoration(
                    labelText: 'settings.searchTimeRange'.tr(),
                  ),
                  items: const ['none', 'day', 'week', 'month', 'year']
                      .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                      .toList(),
                  onChanged: (v) => range = v ?? range,
                ),
              ),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<int>(
                  initialValue: maximum,
                  decoration: InputDecoration(
                    labelText: 'settings.searchMaxResults'.tr(),
                  ),
                  items: List.generate(10, (i) => i + 1)
                      .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                      .toList(),
                  onChanged: (v) => maximum = v ?? maximum,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('save-searxng-settings'),
            onPressed: saving ? null : () => _save(context),
            icon: const Icon(Icons.save_outlined),
            label: Text('common.save'.tr()),
          ),
        ],
      ),
    ),
  );

  Future<void> _save(BuildContext context) async {
    try {
      setState(() => saving = true);
      final base = WebSearchPolicy.validateBaseUrl(endpoint.text.trim());
      final http = Uri.parse(base).scheme == 'http';
      await ref
          .read(searxngSettingsControllerProvider.notifier)
          .save(
            SearxngSearchSettings(
              enabled: enabled,
              baseUrl: base,
              locale: locale,
              timeRange: range,
              maxResults: maximum,
              httpAcknowledgedUrl: http && acknowledged ? base : null,
              hasSecret: widget.initial.hasSecret,
            ),
            secret: http ? null : secret.text,
          );
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('settings.saved'.tr())));
      }
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('common.error'.tr())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }
}
