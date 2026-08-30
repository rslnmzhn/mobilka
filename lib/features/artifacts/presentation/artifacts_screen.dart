import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/application/chat_controller.dart';
import '../application/artifacts_controller.dart';
import '../data/artifact_store.dart';
import '../domain/artifact.dart';
import 'artifact_actions.dart';
import 'artifact_catalog.dart';

class ArtifactsScreen extends ConsumerStatefulWidget {
  const ArtifactsScreen({super.key});
  @override
  ConsumerState<ArtifactsScreen> createState() => _ArtifactsScreenState();
}

class _ArtifactsScreenState extends ConsumerState<ArtifactsScreen> {
  String query = '';
  ArtifactOwnershipFilter ownership = ArtifactOwnershipFilter.all;
  ArtifactTypeFilter type = ArtifactTypeFilter.all;
  ArtifactSort sort = ArtifactSort.newest;
  Future<Map<String, ArtifactRepresentations>>? _filesFuture;
  String? _filesKey;

  @override
  Widget build(BuildContext context) {
    final artifacts = ref.watch(artifactsControllerProvider);
    final revision = ref.watch(artifactRepresentationsRevisionProvider);
    final conversations =
        ref.watch(chatControllerProvider).value?.conversations ?? const [];
    final titles = {
      for (final conversation in conversations)
        conversation.id: conversation.title,
    };
    final filesKey = '$revision:${artifacts.map((item) => item.id).join(',')}';
    if (_filesKey != filesKey) {
      _filesKey = filesKey;
      _filesFuture = _representations(artifacts);
    }
    return Scaffold(
      appBar: AppBar(title: Text('artifacts.catalog'.tr())),
      body: FutureBuilder<Map<String, ArtifactRepresentations>>(
        future: _filesFuture,
        builder: (context, snapshot) {
          final files = snapshot.data ?? const {};
          final visible = filterAndSortArtifacts(
            artifacts: artifacts,
            query: query,
            ownership: ownership,
            type: type,
            sort: sort,
            representations: files,
            conversationTitles: titles,
          );
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: TextField(
                      key: const Key('artifact-catalog-search'),
                      onChanged: (value) => setState(() => query = value),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: 'artifacts.search'.tr(),
                      ),
                    ),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        for (final value in ArtifactTypeFilter.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text('artifacts.type.${value.name}'.tr()),
                              selected: type == value,
                              onSelected: (_) => setState(() => type = value),
                            ),
                          ),
                        for (final value in ArtifactOwnershipFilter.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text('artifacts.owner.${value.name}'.tr()),
                              selected: ownership == value,
                              onSelected: (_) =>
                                  setState(() => ownership = value),
                            ),
                          ),
                        DropdownButton<ArtifactSort>(
                          value: sort,
                          items: [
                            for (final value in ArtifactSort.values)
                              DropdownMenuItem(
                                value: value,
                                child: Text(
                                  'artifacts.sort.${value.name}'.tr(),
                                ),
                              ),
                          ],
                          onChanged: (value) => setState(() => sort = value!),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: visible.isEmpty
                        ? Center(child: Text('artifacts.noDocuments'.tr()))
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: visible.length,
                            itemBuilder: (context, index) => _ArtifactTile(
                              artifact: visible[index],
                              files: files[visible[index].id],
                              owner: artifactOwner(visible[index], titles),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<Map<String, ArtifactRepresentations>> _representations(
    List<Artifact> artifacts,
  ) async {
    final files = ref.read(localArtifactFilesProvider);
    final result = <String, ArtifactRepresentations>{};
    for (final artifact in artifacts.take(100)) {
      final md = await files.stat(artifact.id, extension: 'md');
      final docx = await files.stat(artifact.id, extension: 'docx');
      result[artifact.id] = ArtifactRepresentations(
        markdownBytes: md?.size,
        docxBytes: docx?.size,
      );
    }
    return result;
  }
}

class _ArtifactTile extends ConsumerWidget {
  const _ArtifactTile({
    required this.artifact,
    required this.owner,
    this.files,
  });
  final Artifact artifact;
  final ArtifactRepresentations? files;
  final ({ArtifactOwnerKind kind, String? title, String? sessionKey}) owner;

  String _ownerLabel() {
    final label = switch (owner.kind) {
      ArtifactOwnerKind.unowned => 'artifacts.owner.unowned'.tr(),
      ArtifactOwnerKind.resolved => owner.title!,
      ArtifactOwnerKind.unavailable => 'artifacts.owner.unavailable'.tr(),
    };
    final sessionKey = owner.sessionKey;
    return sessionKey == null || sessionKey.isEmpty
        ? label
        : '$label · $sessionKey';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
    key: Key('artifact-catalog-${artifact.id}'),
    title: Text(artifact.title, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      [
        _ownerLabel(),
        if (files?.hasMarkdown == true) 'MD',
        if (files?.hasDocx == true) 'DOCX',
      ].join(' · '),
    ),
    onTap: () async {
      await openArtifactEditor(context, ref, artifact);
      ref.read(artifactRepresentationsRevisionProvider.notifier).state++;
    },
    trailing: PopupMenuButton<String>(
      onSelected: (value) async {
        if (value == 'share') {
          await safeShareArtifact(context, ref, artifact);
        } else {
          await confirmDeleteArtifact(context, ref, artifact);
        }
        ref.read(artifactRepresentationsRevisionProvider.notifier).state++;
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'share', child: Text('artifacts.share'.tr())),
        PopupMenuItem(value: 'delete', child: Text('chat.delete'.tr())),
      ],
    ),
  );
}
