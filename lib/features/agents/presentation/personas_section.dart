import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/workbench_widgets.dart';
import '../../memory/application/persona_registry.dart';
import '../../memory/application/memory_mutation_coordinator.dart';
import '../../memory/application/memory_file_editor.dart';
import '../../memory/presentation/memory_editor_sheet.dart';
import 'persona_editor_sheet.dart';

class PersonasSection extends ConsumerWidget {
  const PersonasSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final personas = ref.watch(personaRegistryStateProvider);
    final activeId = ref.watch(activePersonaIdProvider);
    final editor = ref.watch(memoryFileEditorProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WorkbenchSectionLabel(
          label: 'agents.personas'.tr(),
          icon: Icons.theater_comedy_outlined,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: personas.when(
              loading: () => const LinearProgressIndicator(),
              error: (_, _) => const Text('Personas could not be loaded.'),
              data: (personaState) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${'agents.activePersona'.tr()}: ${activeId ?? 'agents.noPersona'.tr()}',
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const Key('persona-create'),
                        onPressed: editor == null ? null : () => _edit(context),
                        icon: const Icon(Icons.add),
                        label: Text('agents.createPersona'.tr()),
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final entry in personaState.entries)
                          ChoiceChip(
                            key: Key('persona-${entry.id}'),
                            label: Text(entry.title),
                            selected: activeId == entry.id,
                            onSelected: (_) async {
                              await ref
                                  .read(personaRegistryStateProvider.notifier)
                                  .switchTo(entry.id);
                            },
                          ),
                        for (final entry in personaState.entries)
                          IconButton(
                            key: Key('persona-edit-${entry.id}'),
                            tooltip: 'agents.editPersona'.tr(),
                            onPressed: () => _edit(context, id: entry.id),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                        for (final entry in personaState.entries)
                          IconButton(
                            key: Key('persona-delete-${entry.id}'),
                            tooltip: 'agents.deletePersona'.tr(),
                            onPressed: () => _delete(context, ref, entry.id),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ActionChip(
                          key: const Key('persona-clear'),
                          label: Text('agents.clearPersona'.tr()),
                          onPressed: () async {
                            await ref
                                .read(personaRegistryStateProvider.notifier)
                                .switchTo(null);
                          },
                        ),
                      ],
                    ),
                    if (personaState.catalog.issues.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text('agents.invalidPersonas'.tr()),
                      for (final issue in personaState.catalog.issues)
                        ListTile(
                          dense: true,
                          title: Text(issue.fileName),
                          subtitle: Text(issue.message),
                          trailing: Wrap(
                            children: [
                              TextButton(
                                key: Key('persona-open-${issue.fileName}'),
                                onPressed: editor == null
                                    ? null
                                    : () => _repair(
                                        context,
                                        editor,
                                        issue.fileName,
                                      ),
                                child: Text('memory.open'.tr()),
                              ),
                              TextButton(
                                key: Key('persona-repair-${issue.fileName}'),
                                onPressed: editor == null
                                    ? null
                                    : () => _repair(
                                        context,
                                        editor,
                                        issue.fileName,
                                      ),
                                child: Text('memory.edit'.tr()),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  void _edit(BuildContext context, {String? id}) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => PersonaEditorSheet(id: id),
  );

  void _repair(
    BuildContext context,
    MemoryFileEditor editor,
    String fileName,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        MemoryEditorSheet(fileName: 'personas/$fileName', editor: editor),
  );

  Future<void> _delete(BuildContext context, WidgetRef ref, String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('agents.deletePersona'.tr()),
        content: Text('agents.deletePersonaConfirm'.tr(args: [id])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('common.cancel'.tr()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('common.delete'.tr()),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final mutations = ref.read(memoryMutationCoordinatorProvider)!;
    final source = await mutations.readIfExists('personas/$id.md');
    if (source == null) return;
    await ref
        .read(personaRegistryProvider)!
        .deleteManual(id, expectedVersion: checksum(source));
    await ref.read(personaRegistryStateProvider.notifier).refresh();
  }
}
