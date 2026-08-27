import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/workbench_widgets.dart';
import '../../memory/application/memory_file_editor.dart';
import '../../memory/application/persona_registry.dart';
import '../../memory/domain/memory_file_names.dart';
import '../../memory/presentation/memory_editor_sheet.dart';

class PersonasSection extends ConsumerWidget {
  const PersonasSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final personas = ref.watch(personaRegistryStateProvider);
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
                      personaState.error ??
                          '${'agents.activePersona'.tr()}: ${personaState.activeName ?? 'agents.noPersona'.tr()}',
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final entry in personaState.entries)
                          ChoiceChip(
                            key: Key('persona-${entry.name}'),
                            label: Text(entry.name),
                            selected: personaState.activeName == entry.name,
                            onSelected: (_) => ref
                                .read(personaRegistryStateProvider.notifier)
                                .switchTo(entry.name),
                          ),
                        ActionChip(
                          key: const Key('persona-clear'),
                          label: Text('agents.clearPersona'.tr()),
                          onPressed: () => ref
                              .read(personaRegistryStateProvider.notifier)
                              .switchTo(null),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: OutlinedButton.icon(
                        key: const Key('persona-edit'),
                        onPressed: editor == null
                            ? null
                            : () async {
                                await showModalBottomSheet<void>(
                                  context: context,
                                  isScrollControlled: true,
                                  builder: (_) => MemoryEditorSheet(
                                    fileName: MemoryFiles.personas,
                                    editor: editor,
                                  ),
                                );
                                if (context.mounted) {
                                  await ref
                                      .read(
                                        personaRegistryStateProvider.notifier,
                                      )
                                      .refresh();
                                }
                              },
                        icon: const Icon(Icons.edit_outlined),
                        label: Text('agents.editPersonas'.tr()),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
