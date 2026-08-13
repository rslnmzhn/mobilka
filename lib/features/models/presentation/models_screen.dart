import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/workbench_widgets.dart';
import '../application/models_controller.dart';

class ModelsScreen extends ConsumerStatefulWidget {
  const ModelsScreen({super.key});

  @override
  ConsumerState<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends ConsumerState<ModelsScreen> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(modelsControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: WorkbenchPageTitle(
          icon: Icons.dns_outlined,
          title: 'models.title'.tr(),
          detail: 'REMOTE CATALOG',
        ),
        actions: [
          IconButton(
            tooltip: 'models.refresh'.tr(),
            onPressed: () =>
                ref.read(modelsControllerProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('${'common.error'.tr()}: $error'),
          ),
        ),
        data: (data) {
          final filtered =
              data.models
                  .where(
                    (model) =>
                        model.id.toLowerCase().contains(query.toLowerCase()),
                  )
                  .toList()
                ..sort((a, b) {
                  final favorite =
                      (data.favorites.contains(b.id) ? 1 : 0) -
                      (data.favorites.contains(a.id) ? 1 : 0);
                  return favorite != 0 ? favorite : a.id.compareTo(b.id);
                });
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 880),
                    child: TextField(
                      onChanged: (value) => setState(() => query = value),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: 'models.search'.tr(),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? Center(child: Text('models.empty'.tr()))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final model = filtered[index];
                          final favorite = data.favorites.contains(model.id);
                          final hidden = data.hidden.contains(model.id);
                          return Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 880),
                              child: Card(
                                child: ListTile(
                                  title: Text(model.id),
                                  subtitle: model.ownedBy == null
                                      ? null
                                      : Text(model.ownedBy!),
                                  leading: IconButton(
                                    tooltip: 'models.favorite'.tr(),
                                    onPressed: () => ref
                                        .read(modelsControllerProvider.notifier)
                                        .toggleFavorite(model.id),
                                    icon: Icon(
                                      favorite ? Icons.star : Icons.star_border,
                                      color: favorite ? Colors.amber : null,
                                    ),
                                  ),
                                  trailing: IconButton(
                                    tooltip: hidden
                                        ? 'models.show'.tr()
                                        : 'models.hide'.tr(),
                                    onPressed: () => ref
                                        .read(modelsControllerProvider.notifier)
                                        .toggleHidden(model.id),
                                    icon: Icon(
                                      hidden
                                          ? Icons.visibility_off
                                          : Icons.visibility,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
