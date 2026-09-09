import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/workspace/workspace_binding.dart';
import '../../documents/domain/document_tool_request.dart';
import '../../documents/domain/document_limits.dart';
import '../../memory/domain/strict_json_object_parser.dart';
import '../../workspace/domain/session_workspace_path.dart';
import 'chat_message.dart';

enum DocumentProposalStatus { pending, claimed }

final class PendingDocumentProposal {
  PendingDocumentProposal._(this._data);

  static const maxPayloadBytes = 1024 * 1024;
  static const maxStorageBytes = 8 * maxPayloadBytes;
  static const invalidProposal = 'invalid_document_proposal';
  static final _hash = RegExp(r'^[0-9a-f]{64}$');
  static const _keys = {
    'version',
    'conversationId',
    'requestId',
    'assistantMessageId',
    'toolCallId',
    'toolCallIndex',
    'callOccurrence',
    'toolName',
    'arguments',
    'selectedAgentId',
    'allowedTools',
    'permissionSnapshot',
    'sessionKey',
    'binding',
    'documentId',
    'sourceIdentity',
    'sourcePath',
    'sourceHash',
    'optionsIdentity',
    'outputDigest',
    'payload',
    'payloadSha256',
    'createdAt',
    'expiresAt',
    'status',
    'claimToken',
    'claimedAt',
  };

  final Map<String, Object?> _data;

  static String digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  factory PendingDocumentProposal.decode(String raw) {
    try {
      if (raw.length > maxStorageBytes ||
          utf8.encode(raw).length > maxStorageBytes) {
        throw const FormatException(invalidProposal);
      }
      return PendingDocumentProposal.fromJson(
        StrictJsonObjectParser.decode(
          raw,
          maxSourceBytes: maxStorageBytes,
          maxDepth: 3,
          maxNodes: 512,
          maxStringBytes: maxPayloadBytes,
        ),
      );
    } on FormatException {
      throw const FormatException(invalidProposal);
    }
  }

  factory PendingDocumentProposal.fromJson(Map<dynamic, dynamic> data) {
    try {
      if (data.length != _keys.length ||
          data.keys.any((key) => !_keys.contains(key))) {
        throw const FormatException(invalidProposal);
      }
      String text(String key, [int maximum = 4096]) {
        final value = data[key];
        if (value is! String ||
            value.isEmpty ||
            value.length > maximum ||
            utf8.encode(value).length > maximum) {
          throw const FormatException(invalidProposal);
        }
        return value;
      }

      // Bound the raw payload before decoding any nested serialized content.
      final payload = text('payload', maxPayloadBytes);
      if (data['version'] != 1 ||
          data['version'] is! int ||
          digest(payload) != text('payloadSha256', 64)) {
        throw const FormatException(invalidProposal);
      }
      for (final key in [
        'conversationId',
        'requestId',
        'assistantMessageId',
        'toolCallId',
        'selectedAgentId',
        'permissionSnapshot',
        'documentId',
        'sourceIdentity',
        'optionsIdentity',
      ]) {
        if (text(key).runes.any((r) => r < 32 || r == 127)) {
          throw const FormatException(invalidProposal);
        }
      }
      for (final key in ['sourceHash', 'outputDigest', 'payloadSha256']) {
        if (!_hash.hasMatch(text(key, 64))) {
          throw const FormatException(invalidProposal);
        }
      }
      final toolCallIndex = data['toolCallIndex'];
      final callOccurrence = data['callOccurrence'];
      if (toolCallIndex is! int ||
          toolCallIndex < 0 ||
          toolCallIndex > 100000 ||
          callOccurrence is! int ||
          callOccurrence < 0 ||
          callOccurrence > 100000 ||
          callOccurrence > toolCallIndex) {
        throw const FormatException(invalidProposal);
      }
      final tools = data['allowedTools'];
      if (tools is! List ||
          tools.isEmpty ||
          tools.length > 256 ||
          tools.any((v) => v is! String || v.isEmpty || v.length > 128) ||
          tools.toSet().length != tools.length ||
          !tools.contains(text('toolName', 128))) {
        throw const FormatException(invalidProposal);
      }
      final request = DocumentToolRequest.parse(
        text('toolName', 128),
        text('arguments'),
      );
      if (request.path.value != text('sourcePath') ||
          request.sourceHash != data['sourceHash']) {
        throw const FormatException(invalidProposal);
      }
      if (SessionWorkspacePath.parse(text('sessionKey')).components.length !=
          1) {
        throw const FormatException(invalidProposal);
      }
      final binding = WorkspaceBindingSnapshot.fromJson(
        StrictJsonObjectParser.decode(
          text('binding', 16384),
          maxDepth: 1,
          maxNodes: 10,
          maxStringBytes: 4096,
        ),
      );
      if (binding.rootIdentity == null ||
          jsonEncode(binding.toJson()) != data['binding']) {
        throw const FormatException(invalidProposal);
      }
      final decoded = StrictJsonObjectParser.decode(
        payload,
        maxDepth: 6,
        maxNodes: 500000,
        maxStringBytes: maxPayloadBytes,
      );
      if (decoded['source_sha256'] != data['sourceHash'] ||
          decoded['options_identity'] != data['optionsIdentity'] ||
          decoded['output_digest'] != data['outputDigest'] ||
          decoded['provenance'] != 'local_document') {
        throw const FormatException(invalidProposal);
      }
      const common = {
        'provenance',
        'source_sha256',
        'options_identity',
        'output_digest',
      };
      final native = request.nativeOptions != null;
      final payloadKeys = {
        ...common,
        if (native) 'pages' else ...{'format', 'fragments', 'warnings'},
      };
      if (decoded.length != payloadKeys.length ||
          decoded.keys.any((key) => !payloadKeys.contains(key))) {
        throw const FormatException(invalidProposal);
      }
      Object digestFields;
      if (native) {
        final pages = decoded['pages'];
        if (pages is! List ||
            pages.isEmpty ||
            pages.length > 25 ||
            pages.any(
              (page) =>
                  page is! List ||
                  page.length != 3 ||
                  page[0] is! int ||
                  page[1] is! bool ||
                  page[2] is! String,
            ) ||
            request.nativeOptions!.sha256Digest != data['optionsIdentity']) {
          throw const FormatException(invalidProposal);
        }
        digestFields = [
          'native-document-tool/1',
          data['sourceHash'],
          data['optionsIdentity'],
          pages,
        ];
      } else {
        final fragments = decoded['fragments'];
        final warnings = decoded['warnings'];
        if (decoded['format'] != request.format.name ||
            fragments is! List ||
            warnings is! List ||
            warnings.any((v) => v is! String) ||
            fragments.any(
              (f) =>
                  f is! List ||
                  f.length != 10 ||
                  f[0] is! String ||
                  f[1] is! String ||
                  [2, 3, 6, 7].any((i) => f[i] != null && f[i] is! int) ||
                  [4, 5, 8, 9].any((i) => f[i] != null && f[i] is! String),
            )) {
          throw const FormatException(invalidProposal);
        }
        final sortedWarnings = warnings.cast<String>().toList()..sort();
        if (jsonEncode(sortedWarnings) != jsonEncode(warnings) ||
            warnings.toSet().length != warnings.length) {
          throw const FormatException(invalidProposal);
        }
        digestFields = [
          'local-document/1',
          decoded['format'],
          data['optionsIdentity'],
          data['sourceHash'],
          fragments,
          warnings,
        ];
      }
      if (digest(jsonEncode(digestFields)) != data['outputDigest']) {
        throw const FormatException(invalidProposal);
      }
      DateTime timestamp(String key) {
        final raw = text(key, 32);
        final value = DateTime.parse(raw);
        if (!value.isUtc || value.toIso8601String() != raw) {
          throw const FormatException(invalidProposal);
        }
        return value;
      }

      final created = timestamp('createdAt');
      final expires = timestamp('expiresAt');
      if (!expires.isAfter(created) ||
          expires.difference(created) > const Duration(hours: 24)) {
        throw const FormatException(invalidProposal);
      }
      final status = data['status'];
      if (status == DocumentProposalStatus.pending.name) {
        if (data['claimToken'] != null || data['claimedAt'] != null) {
          throw const FormatException(invalidProposal);
        }
      } else if (status == DocumentProposalStatus.claimed.name) {
        text('claimToken', 256);
        final claimed = timestamp('claimedAt');
        if (claimed.isBefore(created) || !claimed.isBefore(expires)) {
          throw const FormatException(invalidProposal);
        }
      } else {
        throw const FormatException(invalidProposal);
      }
      return PendingDocumentProposal._(
        Map.unmodifiable({
          ...Map<String, Object?>.from(data),
          'allowedTools': List<String>.unmodifiable(tools.cast<String>()),
        }),
      );
    } on FormatException {
      throw const FormatException(invalidProposal);
    } on DocumentException {
      throw const FormatException(invalidProposal);
    }
  }

  String get conversationId => _data['conversationId']! as String;
  String get requestId => _data['requestId']! as String;
  String get assistantMessageId => _data['assistantMessageId']! as String;
  String get toolCallId => _data['toolCallId']! as String;
  int get toolCallIndex => _data['toolCallIndex']! as int;
  int get callOccurrence => _data['callOccurrence']! as int;
  String get toolName => _data['toolName']! as String;
  String get arguments => _data['arguments']! as String;
  String get selectedAgentId => _data['selectedAgentId']! as String;
  Set<String> get allowedTools =>
      Set.unmodifiable((_data['allowedTools']! as List<String>));
  String get payload => _data['payload']! as String;
  String get payloadSha256 => _data['payloadSha256']! as String;
  DateTime get createdAt => DateTime.parse(_data['createdAt']! as String);
  DateTime get expiresAt => DateTime.parse(_data['expiresAt']! as String);
  DocumentProposalStatus get status =>
      DocumentProposalStatus.values.byName(_data['status']! as String);
  String? get claimToken => _data['claimToken'] as String?;
  String get sessionKey => _data['sessionKey']! as String;

  bool belongsTo({
    required String conversationId,
    required String? requestId,
    required String? sessionKey,
    required List<ChatMessage> messages,
  }) {
    if (this.conversationId != conversationId ||
        this.requestId != requestId ||
        this.sessionKey != sessionKey) {
      return false;
    }
    final requests = messages.where((m) => m.id == this.requestId).toList();
    final assistants = messages
        .where((m) => m.id == assistantMessageId)
        .toList();
    if (requests.length != 1 ||
        requests.single.role != ChatRole.user ||
        assistants.length != 1 ||
        assistants.single.role != ChatRole.assistant) {
      return false;
    }
    final assistant = assistants.single;
    final requestIndex = messages.indexOf(requests.single);
    final assistantIndex = messages.indexOf(assistant);
    if (assistantIndex <= requestIndex ||
        toolCallIndex >= assistant.toolCalls.length ||
        messages
            .skip(requestIndex + 1)
            .take(assistantIndex - requestIndex - 1)
            .any((m) => m.role == ChatRole.user)) {
      return false;
    }
    final call = assistant.toolCalls[toolCallIndex];
    return call.id == toolCallId &&
        call.name == toolName &&
        call.arguments == arguments &&
        assistant.toolCalls
                .take(toolCallIndex)
                .where((c) => c.id == toolCallId)
                .length ==
            callOccurrence;
  }

  PendingDocumentProposal pending() => PendingDocumentProposal.fromJson({
    ..._data,
    'status': DocumentProposalStatus.pending.name,
    'claimToken': null,
    'claimedAt': null,
  });

  Map<String, Object?> toJson() => Map.of(_data);
  String encode() => jsonEncode(_data);

  PendingDocumentProposal claim(String token, DateTime now) {
    if (status != DocumentProposalStatus.pending) {
      throw const FormatException(invalidProposal);
    }
    return PendingDocumentProposal.fromJson({
      ..._data,
      'status': DocumentProposalStatus.claimed.name,
      'claimToken': token,
      'claimedAt': now.toUtc().toIso8601String(),
    });
  }
}
