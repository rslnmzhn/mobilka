import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

class PendingSkillProposalCard extends StatefulWidget {
  const PendingSkillProposalCard({
    required this.name,
    required this.oldContent,
    required this.proposedContent,
    required this.sourceDerived,
    required this.warningCount,
    required this.isBusy,
    required this.onConfirm,
    required this.onReject,
    super.key,
  });
  final String name;
  final String? oldContent;
  final String proposedContent;
  final bool sourceDerived;
  final int warningCount;
  final bool isBusy;
  final Future<void> Function() onConfirm;
  final Future<void> Function() onReject;

  @override
  State<PendingSkillProposalCard> createState() => _State();
}

class _State extends State<PendingSkillProposalCard> {
  var busy = false;
  String? error;
  Future<void> run(Future<void> Function() action) async {
    if (busy || widget.isBusy) return;
    setState(() => busy = true);
    try {
      await action();
    } on Object {
      if (mounted) {
        setState(() => error = 'chat.memoryConfirmError'.tr());
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('pending-skill-proposal'),
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
    child: Padding(padding: const EdgeInsets.all(14), child: _content(context)),
  );

  Widget _content(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        (widget.oldContent == null ? 'chat.skillCreate' : 'chat.skillUpdate')
            .tr(args: ['${widget.name}.md']),
        style: Theme.of(context).textTheme.titleSmall,
      ),
      if (widget.sourceDerived) Text('chat.skillSourceWarning'.tr()),
      if (widget.warningCount > 0)
        Text('chat.skillGuardWarning'.tr(args: ['${widget.warningCount}'])),
      if (error != null)
        Text(
          error!,
          key: const Key('skill-proposal-error'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      const SizedBox(height: 8),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: SingleChildScrollView(
          child: SelectableText(
            _diff(widget.oldContent, widget.proposedContent),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ),
      Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        children: [
          TextButton(
            onPressed: busy || widget.isBusy
                ? null
                : () => run(widget.onReject),
            child: Text('chat.rejectMemory'.tr()),
          ),
          FilledButton(
            onPressed: busy || widget.isBusy
                ? null
                : () => run(widget.onConfirm),
            child: Text('chat.confirmMemory'.tr()),
          ),
        ],
      ),
    ],
  );
}

String _diff(String? oldContent, String proposed) {
  if (oldContent == null) return proposed;
  final oldLines = oldContent.split('\n');
  final newLines = proposed.split('\n');
  var prefix = 0;
  while (prefix < oldLines.length &&
      prefix < newLines.length &&
      oldLines[prefix] == newLines[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < oldLines.length - prefix &&
      suffix < newLines.length - prefix &&
      oldLines[oldLines.length - 1 - suffix] ==
          newLines[newLines.length - 1 - suffix]) {
    suffix++;
  }
  return [
    '--- current',
    '+++ proposed',
    ...oldLines.take(prefix).map((line) => ' $line'),
    ...oldLines
        .skip(prefix)
        .take(oldLines.length - prefix - suffix)
        .map((line) => '-$line'),
    ...newLines
        .skip(prefix)
        .take(newLines.length - prefix - suffix)
        .map((line) => '+$line'),
    ...oldLines.skip(oldLines.length - suffix).map((line) => ' $line'),
  ].join('\n');
}
