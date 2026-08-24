import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../application/artifact_policy.dart';
import '../domain/artifact.dart';

/// Modal editor for creating or editing a Markdown document artifact.
///
/// [onSave] receives the trimmed title and raw content; policy violations are
/// surfaced inline from the thrown [ArtifactPolicyException]. For existing
/// documents the optional [onOpen]/[onExportDocx] actions expose native open
/// (roadmap item 42) and `.docx` generation in the sheet footer.
class DocumentEditorSheet extends StatefulWidget {
  const DocumentEditorSheet({
    required this.onSave,
    this.artifact,
    this.onOpen,
    this.onExportDocx,
    super.key,
  });

  final Artifact? artifact;
  final Future<void> Function(String title, String content) onSave;
  final Future<void> Function()? onOpen;
  final Future<void> Function()? onExportDocx;

  @override
  State<DocumentEditorSheet> createState() => _DocumentEditorSheetState();
}

class _DocumentEditorSheetState extends State<DocumentEditorSheet> {
  late final TextEditingController _title = TextEditingController(
    text: widget.artifact?.title ?? '',
  );
  late final TextEditingController _content = TextEditingController(
    text: widget.artifact?.content ?? '',
  );

  var _busy = false;
  String? _errorKey;

  bool get _canSave =>
      !_busy && _title.text.trim().isNotEmpty && _content.text.isNotEmpty;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _errorKey = null;
    });
    try {
      await action();
    } on ArtifactPolicyException catch (error) {
      if (mounted) setState(() => _errorKey = error.messageKey);
    } on Object {
      if (mounted) setState(() => _errorKey = 'common.error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() {
    return _run(() async {
      await widget.onSave(_title.text.trim(), _content.text);
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    heightFactor: 0.85,
    child: Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            (widget.artifact == null ? 'artifacts.create' : 'artifacts.edit')
                .tr(),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('artifact-title-field'),
            controller: _title,
            enabled: !_busy,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'artifacts.documentTitle'.tr(),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: TextField(
              key: const Key('artifact-content-field'),
              controller: _content,
              enabled: !_busy,
              onChanged: (_) => setState(() {}),
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                labelText: 'artifacts.documentContent'.tr(),
                alignLabelWithHint: true,
              ),
            ),
          ),
          if (_errorKey case final errorKey?) ...[
            const SizedBox(height: 8),
            Text(
              errorKey.tr(),
              key: const Key('artifact-editor-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (widget.artifact != null) ...[
                TextButton.icon(
                  key: const Key('artifact-open'),
                  onPressed: _busy || widget.onOpen == null
                      ? null
                      : () => _run(widget.onOpen!),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text('artifacts.open'.tr()),
                ),
                TextButton.icon(
                  key: const Key('artifact-export-docx'),
                  onPressed: _busy || widget.onExportDocx == null
                      ? null
                      : () => _run(widget.onExportDocx!),
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: Text('artifacts.exportDocx'.tr()),
                ),
              ],
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text('common.cancel'.tr()),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('artifact-save'),
                onPressed: _canSave ? _save : null,
                child: Text('common.save'.tr()),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
