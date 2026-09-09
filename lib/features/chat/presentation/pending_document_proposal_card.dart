import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

class PendingDocumentProposalCard extends StatelessWidget {
  const PendingDocumentProposalCard({
    required this.path,
    required this.hash,
    required this.payload,
    required this.isBusy,
    required this.onConfirm,
    required this.onReject,
    super.key,
  });
  final String path;
  final String hash;
  final String payload;
  final bool isBusy;
  final Future<void> Function() onConfirm;
  final Future<void> Function() onReject;

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('pending-document-proposal'),
    margin: const EdgeInsets.all(12),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'documentDisclosure.title'.tr(),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          SelectableText('$path\n$hash', maxLines: 3),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              child: SelectableText(_preview(payload)),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                key: const Key('reject-document-proposal'),
                onPressed: isBusy ? null : onReject,
                child: Text('documentDisclosure.reject'.tr()),
              ),
              FilledButton(
                key: const Key('confirm-document-proposal'),
                onPressed: isBusy ? null : onConfirm,
                child: Text('documentDisclosure.confirm'.tr()),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  static String _preview(String payload) {
    final decoded = jsonDecode(payload) as Map;
    final fragments = decoded['fragments'] as List?;
    if (fragments != null) {
      return fragments.map((item) => (item as List).first).join('\n');
    }
    final pages = decoded['pages'] as List?;
    return pages?.map((item) => (item as List).last).join('\n') ?? '';
  }
}
