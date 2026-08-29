import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../models/application/models_controller.dart';
import '../../models/domain/ai_model.dart';

class ChatHeaderBar extends StatelessWidget implements PreferredSizeWidget {
  const ChatHeaderBar({
    required this.title,
    required this.modelId,
    required this.onModelPressed,
    required this.onNewChat,
    super.key,
  });

  final String title;
  final String? modelId;
  final VoidCallback onModelPressed;
  final VoidCallback? onNewChat;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) => AppBar(
    automaticallyImplyLeading: false,
    title: ChatHeader(
      title: title,
      modelId: modelId,
      onModelPressed: onModelPressed,
    ),
    actions: [
      IconButton(
        key: const Key('new-chat'),
        tooltip: 'chat.newConversation'.tr(),
        onPressed: onNewChat,
        icon: const Icon(Icons.add_comment_outlined),
      ),
      const SizedBox(width: 4),
    ],
  );
}

class ChatHeader extends StatelessWidget {
  const ChatHeader({
    required this.title,
    required this.modelId,
    required this.onModelPressed,
    super.key,
  });

  final String title;
  final String? modelId;
  final VoidCallback onModelPressed;

  @override
  Widget build(BuildContext context) {
    final label = modelId ?? 'chat.selectModel'.tr();
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        Tooltip(
          message: 'chatChangeModel'.tr(args: [label]),
          child: Semantics(
            button: true,
            label: 'chatChangeModel'.tr(args: [label]),
            child: InkWell(
              key: const Key('chat-header-model'),
              onTap: onModelPressed,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(color: primary),
                    ),
                  ),
                  const SizedBox(width: 3),
                  ExcludeSemantics(
                    child: Icon(
                      Icons.tune,
                      key: const Key('chat-header-model-icon'),
                      size: 14,
                      color: primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

@visibleForTesting
class ModelPickerSheet extends StatefulWidget {
  const ModelPickerSheet({required this.models, super.key});

  final ModelsState models;

  @override
  State<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<ModelPickerSheet> {
  final searchController = TextEditingController();
  String query = '';

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final models =
        widget.models.visibleModels.where((model) {
          final needle = query.trim().toLowerCase();
          return needle.isEmpty ||
              model.id.toLowerCase().contains(needle) ||
              (model.ownedBy?.toLowerCase().contains(needle) ?? false);
        }).toList()..sort((a, b) {
          final favoriteOrder = _favoriteRank(a).compareTo(_favoriteRank(b));
          return favoriteOrder != 0 ? favoriteOrder : a.id.compareTo(b.id);
        });

    return FractionallySizedBox(
      heightFactor: 0.82,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'chat.selectModel'.tr(),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'common.close'.tr(),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'models.search'.tr(),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'chat.clearSearch'.tr(),
                        onPressed: () {
                          searchController.clear();
                          setState(() => query = '');
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
              onChanged: (value) => setState(() => query = value),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: models.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        widget.models.visibleModels.isEmpty
                            ? 'models.empty'.tr()
                            : 'chat.noModelsFound'.tr(),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: models.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (context, index) {
                      final model = models[index];
                      final favorite = widget.models.favorites.contains(
                        model.id,
                      );
                      final selected =
                          model.id == widget.models.selectedModelId;
                      return ListTile(
                        leading: Icon(
                          favorite ? Icons.star : Icons.memory_outlined,
                          color: favorite
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        title: Text(model.id),
                        subtitle: model.ownedBy == null
                            ? null
                            : Text(model.ownedBy!),
                        trailing: selected
                            ? Icon(
                                Icons.check_circle,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : null,
                        selected: selected,
                        onTap: () => Navigator.pop(context, model.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  int _favoriteRank(AiModel model) =>
      widget.models.favorites.contains(model.id) ? 0 : 1;
}
