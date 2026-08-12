import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/delegation_controller.dart';
import '../domain/agent_catalog.dart';

class DelegationSheet extends ConsumerStatefulWidget {
  const DelegationSheet({
    required this.subagents,
    required this.fallbackModel,
    super.key,
  });

  final List<AgentCatalogEntry> subagents;
  final String fallbackModel;

  @override
  ConsumerState<DelegationSheet> createState() => _DelegationSheetState();
}

class _DelegationSheetState extends ConsumerState<DelegationSheet> {
  final conversationId = TextEditingController();
  final requestId = TextEditingController();
  final task = TextEditingController();
  final delegationContext = TextEditingController();
  late String subagentId = widget.subagents.first.definition.id;

  @override
  void dispose() {
    conversationId.dispose();
    requestId.dispose();
    task.dispose();
    delegationContext.dispose();
    super.dispose();
  }

  void execute() {
    ref
        .read(delegationControllerProvider.notifier)
        .execute(
          parentConversationId: conversationId.text,
          parentRequestId: requestId.text,
          subagentId: subagentId,
          task: task.text,
          context: delegationContext.text,
          fallbackModel: widget.fallbackModel,
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(delegationControllerProvider);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'agents.delegationPreview'.tr(),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            DropdownButtonFormField<String>(
              initialValue: subagentId,
              items: widget.subagents
                  .map(
                    (entry) => DropdownMenuItem(
                      value: entry.definition.id,
                      child: Text(entry.definition.name),
                    ),
                  )
                  .toList(),
              onChanged: state.isRunning
                  ? null
                  : (value) => subagentId = value!,
            ),
            TextField(
              controller: conversationId,
              decoration: InputDecoration(
                labelText: 'agents.parentConversationId'.tr(),
              ),
            ),
            TextField(
              controller: requestId,
              decoration: InputDecoration(
                labelText: 'agents.parentRequestId'.tr(),
              ),
            ),
            TextField(
              controller: task,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(labelText: 'agents.task'.tr()),
            ),
            TextField(
              controller: delegationContext,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(labelText: 'agents.context'.tr()),
            ),
            const SizedBox(height: 12),
            if (state.isRunning)
              OutlinedButton.icon(
                onPressed: () =>
                    ref.read(delegationControllerProvider.notifier).cancel(),
                icon: const Icon(Icons.stop),
                label: Text(
                  MaterialLocalizations.of(context).cancelButtonLabel,
                ),
              )
            else
              FilledButton.icon(
                onPressed: execute,
                icon: const Icon(Icons.play_arrow),
                label: Text('agents.execute'.tr()),
              ),
            if (state.status != DelegationExecutionStatus.idle) ...[
              const SizedBox(height: 12),
              Text(
                state.status.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (state.isRunning)
                const LinearProgressIndicator()
              else if (state.result != null)
                SelectableText(state.result!.error ?? state.result!.content)
              else if (state.error != null)
                SelectableText(state.error!),
            ],
          ],
        ),
      ),
    );
  }
}
