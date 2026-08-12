import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../application/memory_file_editor.dart';

class MemoryEditorSheet extends StatefulWidget {
  const MemoryEditorSheet({
    required this.fileName,
    required this.editor,
    super.key,
  });

  final String fileName;
  final MemoryFileEditor editor;

  @override
  State<MemoryEditorSheet> createState() => _MemoryEditorSheetState();
}

class _MemoryEditorSheetState extends State<MemoryEditorSheet> {
  final _controller = TextEditingController();
  Object? _error;
  var _loading = true;
  String? _version;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snapshot = await widget.editor.read(widget.fileName);
      _controller.text = snapshot.content;
      _version = snapshot.version;
    } on Object catch (error) {
      _error = error;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.editor.save(
        widget.fileName,
        _controller.text,
        expectedVersion: _version!,
      );
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.fileName,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                '${'common.error'.tr()}: $_error',
                key: const Key('memory-editor-error'),
              ),
            TextField(
              key: const Key('memory-editor-content'),
              controller: _controller,
              enabled: !_loading && _error == null,
              minLines: 10,
              maxLines: 20,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('memory-editor-save'),
              onPressed: _loading || _error != null ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: Text('common.save'.tr()),
            ),
          ],
        ),
      ),
    ),
  );
}
