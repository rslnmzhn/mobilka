import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../domain/chat_message.dart';
import '../domain/tool_execution.dart';

enum ToolCardStatus { running, completed, failed }

class ToolCardData {
  const ToolCardData({
    required this.call,
    required this.status,
    this.output,
    this.error,
    this.awaitingConfirmation = false,
  });

  factory ToolCardData.fromExecution(ToolExecution execution) => ToolCardData(
    call: execution.call,
    status: switch (execution.status) {
      ToolExecutionStatus.running => ToolCardStatus.running,
      ToolExecutionStatus.completed => ToolCardStatus.completed,
      ToolExecutionStatus.failed => ToolCardStatus.failed,
    },
    output: execution.result?.content,
    error: execution.error,
    awaitingConfirmation: execution.awaitingConfirmation,
  );

  final ChatToolCall call;
  final ToolCardStatus status;
  final String? output;
  final String? error;
  final bool awaitingConfirmation;
}

class ToolCallCard extends StatefulWidget {
  const ToolCallCard({required this.data, super.key});

  final ToolCardData data;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final statusColor = switch (widget.data.status) {
      ToolCardStatus.running => colors.primary,
      ToolCardStatus.completed => colors.tertiary,
      ToolCardStatus.failed => colors.error,
    };
    final statusLabel = widget.data.awaitingConfirmation
        ? 'chat.toolAwaitingConfirmation'.tr()
        : switch (widget.data.status) {
            ToolCardStatus.running => 'chat.toolRunning'.tr(),
            ToolCardStatus.completed => 'chat.toolCompleted'.tr(),
            ToolCardStatus.failed => 'chat.toolFailed'.tr(),
          };

    return Container(
      key: Key('tool-call-${widget.data.call.id}'),
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            label: '${widget.data.call.name}, $statusLabel',
            child: InkWell(
              key: Key('tool-call-toggle-${widget.data.call.id}'),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    _StatusIcon(status: widget.data.status, color: statusColor),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 3,
                      child: Text(
                        widget.data.call.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      flex: 2,
                      child: Text(
                        statusLabel,
                        key: Key('tool-call-status-${widget.data.call.id}'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: statusColor),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, color: colors.outlineVariant),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Payload(
                    label: 'chat.toolInput'.tr(),
                    value: widget.data.call.arguments,
                    valueKey: Key('tool-call-input-${widget.data.call.id}'),
                  ),
                  if (widget.data.error case final error?) ...[
                    const SizedBox(height: 10),
                    _Payload(
                      label: 'chat.toolError'.tr(),
                      value: error,
                      color: colors.error,
                      valueKey: Key('tool-call-error-${widget.data.call.id}'),
                    ),
                  ] else if (widget.data.output case final output?) ...[
                    const SizedBox(height: 10),
                    _Payload(
                      label: 'chat.toolOutput'.tr(),
                      value: output,
                      valueKey: Key('tool-call-output-${widget.data.call.id}'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status, required this.color});

  final ToolCardStatus status;
  final Color color;

  @override
  Widget build(BuildContext context) => switch (status) {
    ToolCardStatus.running => SizedBox.square(
      dimension: 16,
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    ),
    ToolCardStatus.completed => Icon(
      Icons.check_circle_outline,
      size: 18,
      color: color,
    ),
    ToolCardStatus.failed => Icon(Icons.error_outline, size: 18, color: color),
  };
}

class _Payload extends StatelessWidget {
  const _Payload({
    required this.label,
    required this.value,
    required this.valueKey,
    this.color,
  });

  final String label;
  final String value;
  final Key valueKey;
  final Color? color;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelSmall),
      const SizedBox(height: 4),
      Container(
        constraints: const BoxConstraints(maxHeight: 180),
        padding: const EdgeInsets.all(10),
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: SingleChildScrollView(
          child: SelectableText(
            _pretty(value),
            key: valueKey,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: color,
            ),
          ),
        ),
      ),
    ],
  );

  static String _pretty(String value) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(value));
    } on FormatException {
      return value;
    }
  }
}
