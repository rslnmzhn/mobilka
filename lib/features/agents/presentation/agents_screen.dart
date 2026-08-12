import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/application/models_controller.dart';
import '../application/agents_controller.dart';
import '../application/subagent_executor.dart';
import '../domain/agent_catalog.dart';
import '../domain/agent_definition.dart';
import 'delegation_sheet.dart';

class AgentsScreen extends ConsumerWidget {
  const AgentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(agentsControllerProvider);
    final controller = ref.read(agentsControllerProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: Text('agents.title'.tr()),
        actions: [
          IconButton(
            tooltip: 'agents.import'.tr(),
            onPressed: state.isLoading ? null : controller.importAgent,
            icon: const Icon(Icons.file_open_outlined),
          ),
          IconButton(
            tooltip: 'agents.create'.tr(),
            onPressed: state.isLoading
                ? null
                : () => _showEditor(context, controller),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            _ErrorView(error: error, onRetry: controller.refresh),
        data: (catalog) => _AgentList(catalog: catalog, controller: controller),
      ),
      floatingActionButton: MediaQuery.sizeOf(context).width < 600
          ? FloatingActionButton.extended(
              onPressed: state.isLoading
                  ? null
                  : () => _showEditor(context, controller),
              icon: const Icon(Icons.add),
              label: Text('agents.create'.tr()),
            )
          : null,
    );
  }

  Future<void> _showEditor(
    BuildContext context,
    AgentsController controller, [
    AgentCatalogEntry? entry,
  ]) async {
    final definition = await showModalBottomSheet<AgentDefinition>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => AgentEditorSheet(initial: entry?.definition),
    );
    if (definition == null) return;
    if (entry == null) {
      await controller.create(definition);
    } else {
      await controller.edit(entry.definition.id, definition);
    }
  }
}

class _AgentList extends ConsumerWidget {
  const _AgentList({required this.catalog, required this.controller});

  final AgentCatalog catalog;
  final AgentsController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (catalog.agents.isEmpty && catalog.issues.isEmpty) {
      return Center(child: Text('agents.empty'.tr()));
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
          children: [
            ref
                .watch(agentGraphProvider)
                .when(
                  data: (graph) => graph.selectedPrimary == null
                      ? const SizedBox.shrink()
                      : Card(
                          child: ListTile(
                            leading: const Icon(Icons.account_tree_outlined),
                            title: Text('agents.availableSubagents'.tr()),
                            subtitle: Text(
                              graph.selectedAvailableSubagents.isEmpty
                                  ? 'agents.noAvailableSubagents'.tr()
                                  : graph.selectedAvailableSubagents
                                        .map((entry) => entry.definition.name)
                                        .join(', '),
                            ),
                            trailing: graph.selectedAvailableSubagents.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'agents.delegate'.tr(),
                                    icon: const Icon(Icons.call_split),
                                    onPressed: () => _showDelegation(
                                      context,
                                      ref,
                                      graph.selectedAvailableSubagents,
                                    ),
                                  ),
                          ),
                        ),
                  loading: () => const LinearProgressIndicator(),
                  error: (error, _) => Text(error.toString()),
                ),
            if (catalog.issues.isNotEmpty)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ExpansionTile(
                  leading: const Icon(Icons.warning_amber_outlined),
                  title: Text(
                    'agents.invalidFiles'.tr(
                      args: ['${catalog.issues.length}'],
                    ),
                  ),
                  children: catalog.issues
                      .map(
                        (issue) => ListTile(
                          dense: true,
                          title: Text(issue.location),
                          subtitle: Text(issue.message),
                        ),
                      )
                      .toList(),
                ),
              ),
            ...catalog.agents.map((entry) {
              final definition = entry.definition;
              final selected = catalog.selectedId == definition.id;
              return Card(
                child: ListTile(
                  enabled: !entry.isHidden,
                  leading: IconButton(
                    tooltip: 'agents.favorite'.tr(),
                    onPressed: () => controller.toggleFavorite(entry),
                    icon: Icon(
                      entry.isFavorite ? Icons.star : Icons.star_border,
                      color: entry.isFavorite ? Colors.amber : null,
                    ),
                  ),
                  title: Row(
                    children: [
                      Flexible(child: Text(definition.name)),
                      if (selected) ...[
                        const SizedBox(width: 8),
                        const Icon(Icons.check_circle, size: 18),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    '${definition.description}\n${definition.mode.name} · ${entry.origin.name} · ${definition.id}',
                  ),
                  isThreeLine: true,
                  onTap: entry.isSelectable
                      ? () => controller.select(definition.id)
                      : null,
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) async {
                      switch (action) {
                        case 'visibility':
                          await controller.toggleHidden(entry);
                          break;
                        case 'edit':
                          final edited =
                              await showModalBottomSheet<AgentDefinition>(
                                context: context,
                                isScrollControlled: true,
                                useSafeArea: true,
                                builder: (_) =>
                                    AgentEditorSheet(initial: definition),
                              );
                          if (edited != null) {
                            await controller.edit(definition.id, edited);
                          }
                          break;
                        case 'delete':
                          await controller.delete(definition.id);
                          break;
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'visibility',
                        child: Text(
                          entry.isHidden
                              ? 'agents.show'.tr()
                              : 'agents.hide'.tr(),
                        ),
                      ),
                      if (entry.origin == AgentOrigin.user)
                        PopupMenuItem(
                          value: 'edit',
                          child: Text('agents.edit'.tr()),
                        ),
                      if (entry.origin == AgentOrigin.user)
                        PopupMenuItem(
                          value: 'delete',
                          child: Text('agents.delete'.tr()),
                        ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Future<void> _showDelegation(
    BuildContext context,
    WidgetRef ref,
    List<AgentCatalogEntry> subagents,
  ) async {
    final model = ref.read(modelsControllerProvider).value?.selectedModelId;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) =>
          DelegationSheet(subagents: subagents, fallbackModel: model ?? ''),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${'common.error'.tr()}: $error'),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: Text('agents.retry'.tr())),
        ],
      ),
    ),
  );
}

class AgentEditorSheet extends StatefulWidget {
  const AgentEditorSheet({this.initial, super.key});
  final AgentDefinition? initial;

  @override
  State<AgentEditorSheet> createState() => _AgentEditorSheetState();
}

class _AgentEditorSheetState extends State<AgentEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _id;
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _model;
  late final TextEditingController _subagents;
  late final TextEditingController _tools;
  late final TextEditingController _prompt;
  late AgentMode _mode;

  @override
  void initState() {
    super.initState();
    final value = widget.initial;
    _id = TextEditingController(text: value?.id);
    _name = TextEditingController(text: value?.name);
    _description = TextEditingController(text: value?.description);
    _model = TextEditingController(text: value?.modelPreference);
    _subagents = TextEditingController(text: value?.subagents.join(', '));
    _tools = TextEditingController(text: value?.tools.join(', '));
    _prompt = TextEditingController(text: value?.prompt);
    _mode = value?.mode ?? AgentMode.primary;
  }

  @override
  void dispose() {
    for (final controller in [
      _id,
      _name,
      _description,
      _model,
      _subagents,
      _tools,
      _prompt,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  List<String> _ids(TextEditingController controller) => controller.text
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      AgentDefinition(
        id: _id.text.trim(),
        name: _name.text.trim(),
        description: _description.text.trim(),
        mode: _mode,
        modelPreference: _model.text.trim().isEmpty ? null : _model.text.trim(),
        subagents: _ids(_subagents),
        tools: _ids(_tools),
        prompt: _prompt.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String? required(String? value) =>
        value == null || value.trim().isEmpty ? 'agents.required'.tr() : null;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.initial == null
                    ? 'agents.create'.tr()
                    : 'agents.edit'.tr(),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _id,
                decoration: InputDecoration(labelText: 'agents.id'.tr()),
                validator: required,
              ),
              TextFormField(
                controller: _name,
                decoration: InputDecoration(labelText: 'agents.name'.tr()),
                validator: required,
              ),
              TextFormField(
                controller: _description,
                decoration: InputDecoration(
                  labelText: 'agents.description'.tr(),
                ),
                validator: required,
              ),
              DropdownButtonFormField<AgentMode>(
                initialValue: _mode,
                decoration: InputDecoration(labelText: 'agents.mode'.tr()),
                items: AgentMode.values
                    .map(
                      (mode) =>
                          DropdownMenuItem(value: mode, child: Text(mode.name)),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _mode = value!),
              ),
              TextFormField(
                controller: _model,
                decoration: InputDecoration(labelText: 'agents.model'.tr()),
              ),
              if (_mode == AgentMode.primary)
                TextFormField(
                  controller: _subagents,
                  decoration: InputDecoration(
                    labelText: 'agents.subagents'.tr(),
                  ),
                ),
              TextFormField(
                controller: _tools,
                decoration: InputDecoration(labelText: 'agents.tools'.tr()),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _prompt,
                minLines: 8,
                maxLines: 16,
                decoration: InputDecoration(
                  labelText: 'agents.prompt'.tr(),
                  border: const OutlineInputBorder(),
                ),
                validator: required,
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _save, child: Text('common.save'.tr())),
            ],
          ),
        ),
      ),
    );
  }
}
