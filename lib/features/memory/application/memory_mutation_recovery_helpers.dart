part of 'memory_mutation_coordinator.dart';

enum _RecoveryOutcome { committed, rolledBack }

String _append(String content, Map<String, dynamic> entry) {
  final line = jsonEncode(entry);
  if (content.isEmpty) return '$line\n';
  return content.endsWith('\n') ? '$content$line\n' : '$content\n$line\n';
}

Map<String, dynamic> _terminalAuditEntry(
  Map<String, dynamic> record,
  String status, {
  required bool recovered,
}) {
  final operationId = record['operationId'] as String;
  return <String, dynamic>{
    'timestamp': record['timestamp'],
    'event': record['event'],
    'operationId': operationId,
    'status': status,
    'auditOperationId': 'memory-mutation:$operationId:$status',
    'files': record['files'],
    'createdFiles': record['createdFiles'],
    if (record['deletedFiles'] != null) 'deletedFiles': record['deletedFiles'],
    'beforeHashes': record['beforeHashes'],
    'afterHashes': record['afterHashes'],
    if (record.containsKey('fileName')) 'fileName': record['fileName'],
    if (record.containsKey('previousVersion'))
      'previousVersion': record['previousVersion'],
    if (record.containsKey('version')) 'version': record['version'],
    if (recovered) 'recovered': true,
  };
}

bool _containsAuditOperation(String content, String auditOperationId) {
  for (final line in const LineSplitter().convert(content)) {
    try {
      final value = jsonDecode(line);
      if (value is Map && value['auditOperationId'] == auditOperationId) {
        return true;
      }
    } on FormatException {
      // Markdown headings and user-authored lines are not audit records.
    }
  }
  return false;
}

String _token() {
  final random = Random.secure();
  return base64UrlEncode(
    List<int>.generate(24, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}
