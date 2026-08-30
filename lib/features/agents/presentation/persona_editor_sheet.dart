import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../memory/application/memory_mutation_coordinator.dart';
import '../../memory/application/persona_registry.dart';
import '../../memory/domain/persona.dart';

class PersonaEditorSheet extends ConsumerStatefulWidget {
  const PersonaEditorSheet({this.id, super.key});
  final String? id;

  @override
  ConsumerState<PersonaEditorSheet> createState() => _PersonaEditorSheetState();
}

class _PersonaEditorSheetState extends ConsumerState<PersonaEditorSheet> {
  final _form = GlobalKey<FormState>();
  late final _id = TextEditingController(text: widget.id);
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _params = TextEditingController(text: '{}');
  final _prompt = TextEditingController();
  String _version = 'missing';
  Object? _error;
  var _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.id != null) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final registry = ref.read(personaRegistryProvider)!;
      final definition = await registry.loadById(widget.id!);
      if (definition == null) throw StateError('Persona is unavailable');
      final source = await ref
          .read(memoryMutationCoordinatorProvider)!
          .readIfExists('personas/${widget.id}.md');
      _version = checksum(source!);
      _title.text = definition.metadata.title;
      _description.text = definition.metadata.description;
      _params.text = const JsonEncoder.withIndent(
        '  ',
      ).convert(definition.metadata.params);
      _prompt.text = definition.prompt;
    } on Object catch (error) {
      _error = error;
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = jsonDecode(_params.text);
      if (raw is! Map) {
        throw const FormatException('Params must be a JSON object');
      }
      final definition = PersonaDefinition(
        metadata: PersonaMetadata(
          id: _id.text,
          title: _title.text,
          description: _description.text,
          params: raw.map((key, value) => MapEntry(key.toString(), value)),
        ),
        prompt: _prompt.text,
      );
      await ref
          .read(personaRegistryProvider)!
          .saveManual(definition: definition, expectedVersion: _version);
      await ref.read(personaRegistryStateProvider.notifier).refresh();
      if (mounted) {
        Navigator.pop(context);
      }
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
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Form(
        key: _form,
        child: ListView(
          children: [
            Text(
              widget.id == null
                  ? 'agents.createPersona'.tr()
                  : 'agents.editPersona'.tr(),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            TextFormField(
              controller: _id,
              enabled: widget.id == null,
              decoration: InputDecoration(labelText: 'agents.id'.tr()),
              validator: (v) => v != null && personaSlugPattern.hasMatch(v)
                  ? null
                  : 'agents.invalidPersonaId'.tr(),
            ),
            TextFormField(
              controller: _title,
              decoration: InputDecoration(labelText: 'agents.name'.tr()),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'agents.required'.tr() : null,
            ),
            TextFormField(
              controller: _description,
              decoration: InputDecoration(labelText: 'agents.description'.tr()),
            ),
            TextFormField(
              controller: _params,
              minLines: 3,
              maxLines: 8,
              decoration: InputDecoration(
                labelText: 'agents.personaParams'.tr(),
              ),
            ),
            TextFormField(
              controller: _prompt,
              minLines: 6,
              maxLines: 16,
              decoration: InputDecoration(labelText: 'agents.prompt'.tr()),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'agents.required'.tr() : null,
            ),
            if (_error != null)
              Text(
                '$_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _loading ? null : _save,
              child: Text('common.save'.tr()),
            ),
          ],
        ),
      ),
    ),
  );
}
