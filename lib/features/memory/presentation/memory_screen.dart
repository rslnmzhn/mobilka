import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/memory_controller.dart';
import '../data/memory_repository.dart';

class MemoryScreen extends ConsumerWidget {
  const MemoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memory = ref.watch(memoryControllerProvider);
    return Scaffold(
      appBar: AppBar(title: Text('memory.title'.tr())),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
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
                        error: (error, _) =>
                            Text('${'common.error'.tr()}: $error'),
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
              const SizedBox(height: 16),
              Text(
                'memory.files'.tr(),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              ...MemoryRepository.templates.keys.map(
                (name) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: Text(name),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
