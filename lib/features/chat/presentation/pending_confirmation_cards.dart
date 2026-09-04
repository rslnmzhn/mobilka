import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

class PendingMemoryProposalCard extends StatefulWidget {
  const PendingMemoryProposalCard({
    required this.fileName,
    required this.diff,
    this.isBusy = false,
    required this.onConfirm,
    required this.onReject,
    super.key,
  });
  final String fileName;
  final String diff;
  final bool isBusy;
  final Future<void> Function() onConfirm;
  final Future<void> Function() onReject;
  @override
  State<PendingMemoryProposalCard> createState() => _MemoryState();
}

class PendingToolProposalCard extends StatefulWidget {
  const PendingToolProposalCard({
    required this.toolName,
    required this.isBusy,
    required this.onConfirm,
    required this.onReject,
    super.key,
  });
  final String toolName;
  final bool isBusy;
  final Future<void> Function() onConfirm;
  final Future<void> Function() onReject;
  @override
  State<PendingToolProposalCard> createState() => _ToolState();
}

class PendingWorkspaceProposalCard extends StatefulWidget {
  const PendingWorkspaceProposalCard({
    required this.operation,
    required this.path,
    required this.preview,
    required this.isBusy,
    required this.onConfirm,
    required this.onReject,
    super.key,
  });

  final String operation;
  final String path;
  final String preview;
  final bool isBusy;
  final Future<void> Function() onConfirm;
  final Future<void> Function() onReject;

  @override
  State<PendingWorkspaceProposalCard> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<PendingWorkspaceProposalCard> {
  var busy = false;

  Future<void> run(Future<void> Function() action) async {
    if (busy || widget.isBusy) return;
    setState(() => busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 920),
    child: Card(
      key: const Key('pending-workspace-proposal'),
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'chat.workspaceProposal'.tr(
                namedArgs: {'operation': widget.operation, 'path': widget.path},
              ),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              padding: const EdgeInsets.all(12),
              color: Theme.of(context).colorScheme.surfaceContainerLowest,
              child: SingleChildScrollView(
                child: SelectableText(
                  widget.preview,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  key: const Key('reject-workspace-proposal'),
                  onPressed: busy || widget.isBusy
                      ? null
                      : () => run(widget.onReject),
                  child: Text('chat.rejectMemory'.tr()),
                ),
                FilledButton(
                  key: const Key('confirm-workspace-proposal'),
                  onPressed: busy || widget.isBusy
                      ? null
                      : () => run(widget.onConfirm),
                  child: busy || widget.isBusy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text('chat.confirmMemory'.tr()),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _ToolState extends State<PendingToolProposalCard> {
  var busy = false;
  Future<void> run(Future<void> Function() action) async {
    if (busy || widget.isBusy) return;
    setState(() => busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('pending-tool-proposal'),
    margin: const EdgeInsets.fromLTRB(20, 8, 20, 4),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'chat.memoryProposal'.tr(args: [widget.toolName]),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                key: const Key('reject-tool-proposal'),
                onPressed: busy || widget.isBusy
                    ? null
                    : () => run(widget.onReject),
                child: Text('chat.rejectMemory'.tr()),
              ),
              FilledButton(
                key: const Key('confirm-tool-proposal'),
                onPressed: busy || widget.isBusy
                    ? null
                    : () => run(widget.onConfirm),
                child: Text('chat.confirmMemory'.tr()),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _MemoryState extends State<PendingMemoryProposalCard> {
  var busy = false;
  String? error;
  bool get isBusy => busy || widget.isBusy;
  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } on Object {
      if (mounted) setState(() => error = 'chat.memoryConfirmError'.tr());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 920),
    child: Card(
      key: const Key('pending-memory-proposal'),
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _content(context),
      ),
    ),
  );

  Widget _content(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'chat.memoryProposal'.tr(args: [widget.fileName]),
        style: Theme.of(context).textTheme.titleSmall,
      ),
      const SizedBox(height: 10),
      Container(
        constraints: const BoxConstraints(maxHeight: 220),
        padding: const EdgeInsets.all(12),
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        child: SingleChildScrollView(
          child: SelectableText(
            widget.diff,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ),
      if (error != null)
        Text(
          error!,
          key: const Key('memory-proposal-error'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        children: [
          TextButton(
            key: const Key('reject-memory-proposal'),
            onPressed: isBusy ? null : () => run(widget.onReject),
            child: Text('chat.rejectMemory'.tr()),
          ),
          FilledButton(
            key: const Key('confirm-memory-proposal'),
            onPressed: isBusy ? null : () => run(widget.onConfirm),
            child: isBusy
                ? const SizedBox.square(
                    key: Key('confirm-memory-proposal-progress'),
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text('chat.confirmMemory'.tr()),
          ),
        ],
      ),
    ],
  );
}
