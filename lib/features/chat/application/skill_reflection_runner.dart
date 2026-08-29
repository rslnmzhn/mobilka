import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/logging/app_logger.dart';
import '../data/chat_repository.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import '../domain/chat_tool.dart';
import '../domain/pending_skill_proposal.dart';
import 'chat_stream_request.dart';
import 'chat_stream_support.dart';
import 'chat_tool_runtime.dart';
import 'conversation_mutation.dart';
import 'request_tool_security_state.dart';

class SkillReflectionRunner {
  const SkillReflectionRunner({
    required this.streamer,
    required this.runtime,
    required this.conversationById,
    required this.persistMutation,
    this.logger,
  });

  final ChatCompletionStreamer streamer;
  final ChatToolRuntime runtime;
  final Conversation? Function(String id) conversationById;
  final PersistConversationMutation persistMutation;
  final AppLogger? logger;

  static const maxRounds = 3;
  static const maxToolCalls = 4;
  static const maxTranscriptBytes = 128 * 1024;
  static const timeout = Duration(seconds: 25);
  static const allowed = {'list_skills', 'read_skill', 'propose_skill'};

  Future<void> run({
    required ChatStreamRequest request,
    required String finalAssistantId,
    required RequestToolSecurityState security,
    required CancelToken cancelToken,
  }) async {
    if (!_eligible(request, security, cancelToken)) return;
    Timer? timer;
    try {
      final child = CancelToken();
      if (cancelToken.isCancelled) return;
      cancelToken.whenCancel.then((_) {
        if (!child.isCancelled) child.cancel('parent cancelled');
      });
      timer = Timer(timeout, () {
        if (!child.isCancelled) child.cancel('reflection timeout');
      });
      await _runBounded(request, finalAssistantId, security, child);
    } on Object catch (error) {
      logger?.log(
        event: 'skill.reflection',
        level: AppLogLevel.warning,
        conversationId: request.conversationId,
        status: 'failed',
        error: error,
      );
    } finally {
      timer?.cancel();
    }
  }

  bool _eligible(
    ChatStreamRequest request,
    RequestToolSecurityState security,
    CancelToken cancellation,
  ) =>
      !cancellation.isCancelled &&
      security.currentSnapshot().hasQualifyingSuccess &&
      request.workspaceBinding != null &&
      request.allowedTools.containsAll(allowed) &&
      conversationById(request.conversationId)?.pendingSkillProposal == null &&
      security.claimReflection();

  Future<void> _runBounded(
    ChatStreamRequest request,
    String finalAssistantId,
    RequestToolSecurityState security,
    CancelToken cancellation,
  ) async {
    _checkCancelled(cancellation);
    final definitions = (await runtime.availableTools(
      allowed,
    )).where((tool) => allowed.contains(tool.name)).toList(growable: false);
    if (definitions.length != allowed.length) return;
    final conversation = conversationById(request.conversationId);
    if (conversation == null) return;
    final transcript = _boundedTranscript(
      conversation.messages,
      request.requestMessageId,
      finalAssistantId,
    );
    if (transcript == null) return;
    final provenance = security.verifiedSnapshot();
    if (provenance.conversationId != request.conversationId ||
        provenance.requestId != request.requestMessageId) {
      return;
    }
    final reflection = _reflectionContext(
      request,
      finalAssistantId,
      provenance,
      cancellation,
    );
    await _runRounds(
      request,
      finalAssistantId,
      definitions,
      transcript,
      reflection,
      cancellation,
    );
  }

  SkillReflectionToolContext _reflectionContext(
    ChatStreamRequest request,
    String finalAssistantId,
    SkillLearningProvenance provenance,
    CancelToken cancellation,
  ) => SkillReflectionToolContext(
    conversationId: request.conversationId,
    requestId: request.requestMessageId,
    assistantMessageId: finalAssistantId,
    provenance: provenance,
    permissionSnapshot: request.workspaceBinding!.permissionSnapshot,
    workspaceBindingSnapshot: request.workspaceBinding!.snapshot,
    selectedAgentId: request.selectedAgentId,
    persistProposal: (proposal) =>
        _persistProposal(request, proposal, cancellation),
  );

  Future<void> _runRounds(
    ChatStreamRequest request,
    String finalAssistantId,
    List<ChatToolDefinition> definitions,
    List<ChatMessage> transcript,
    SkillReflectionToolContext reflection,
    CancelToken cancellation,
  ) async {
    var history = [
      ChatMessage(
        id: '$finalAssistantId-reflection-system',
        role: ChatRole.system,
        content: instruction,
        createdAt: DateTime.now(),
      ),
      ...transcript,
    ];
    final budget = _ReflectionCallBudget();
    for (var round = 0; round < maxRounds; round++) {
      final executable = await _nextCalls(
        request,
        history,
        definitions,
        reflection,
        cancellation,
      );
      if (executable == null || !budget.accept(executable)) return;
      final assistantCall = ChatMessage(
        id: '$finalAssistantId-reflection-call-$round',
        role: ChatRole.assistant,
        content: '',
        createdAt: DateTime.now(),
        toolCalls: executable,
      );
      final results = await _executeCalls(
        request,
        finalAssistantId,
        round,
        executable,
        reflection,
        cancellation,
      );
      if (reflection.proposed) return;
      history = [...history, assistantCall, ...results];
      if (_wireBytes(history) > maxTranscriptBytes) return;
    }
  }

  Future<bool> _persistProposal(
    ChatStreamRequest request,
    PendingSkillProposal proposal,
    CancelToken cancellation,
  ) async {
    _checkCancelled(cancellation);
    final saved = await persistMutation(request.conversationId, (latest) {
      if (latest.pendingRequestMessageId != request.requestMessageId ||
          latest.pendingSkillProposal != null) {
        return null;
      }
      return latest.copyWith(pendingSkillProposal: proposal);
    });
    return saved != null;
  }

  Future<List<ChatToolCall>?> _nextCalls(
    ChatStreamRequest request,
    List<ChatMessage> history,
    List<ChatToolDefinition> definitions,
    SkillReflectionToolContext reflection,
    CancelToken cancellation,
  ) async {
    _checkCancelled(cancellation);
    final buffers = <int, ToolCallBuffer>{};
    var terminal = false;
    String? reason;
    await for (final event in streamer.streamCompletion(
      model: request.modelId,
      messages: history,
      cancelToken: cancellation,
      tools: definitions,
    )) {
      _checkCancelled(cancellation);
      for (final delta in event.toolCallDeltas) {
        buffers.putIfAbsent(delta.index, ToolCallBuffer.new).append(delta);
      }
      terminal = terminal || event.isTerminal;
      reason = event.finishReason ?? reason;
    }
    if (!terminal || reason != 'tool_calls' || buffers.isEmpty) return null;
    final values = buffers.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final calls = values
        .map((entry) => entry.value.build())
        .where((call) => allowed.contains(call.name))
        .where((call) => !reflection.proposed || call.name != 'propose_skill')
        .toList(growable: false);
    return calls.isEmpty ? null : calls;
  }

  Future<List<ChatMessage>> _executeCalls(
    ChatStreamRequest request,
    String assistantId,
    int round,
    List<ChatToolCall> calls,
    SkillReflectionToolContext reflection,
    CancelToken cancellation,
  ) async {
    final results = <ChatMessage>[];
    for (final call in calls) {
      _checkCancelled(cancellation);
      final output = await runtime.executeTool(
        call,
        allowed,
        context: ChatToolExecutionContext(
          conversationId: request.conversationId,
          sessionKey: request.sessionKey,
          workspaceBinding: request.workspaceBinding,
          cancellation: _CancelTokenCancellation(cancellation),
          skillReflection: reflection,
        ),
      );
      _checkCancelled(cancellation);
      results.add(
        ChatMessage(
          id: '$assistantId-reflection-result-$round-${results.length}',
          role: ChatRole.tool,
          content: output,
          createdAt: DateTime.now(),
          toolCallId: call.id,
        ),
      );
    }
    return results;
  }

  List<ChatMessage>? _boundedTranscript(
    List<ChatMessage> messages,
    String requestId,
    String finalAssistantId,
  ) {
    final start = messages.indexWhere((message) => message.id == requestId);
    final end = messages.indexWhere(
      (message) => message.id == finalAssistantId,
    );
    if (start < 0 || end < start) return null;
    final result = <ChatMessage>[];
    for (final message in messages.sublist(start, end + 1)) {
      final compact = message.role == ChatRole.tool
          ? message.copyWith(content: _compactToolResult(message.content))
          : message;
      result.add(compact);
      if (_wireBytes(result) > maxTranscriptBytes) return null;
    }
    return result;
  }

  String _compactToolResult(String raw) {
    if (utf8.encode(raw).length <= 8192) return raw;
    try {
      final value = jsonDecode(raw);
      if (value is Map) {
        return jsonEncode({
          'ok': value['ok'],
          'status': value['status'],
          'file': value['file'],
          'final_url': value['final_url'],
          'summary': 'successful tool output omitted from reflection',
        });
      }
    } on FormatException {
      // Fall through to a non-content summary.
    }
    return '{"summary":"bounded tool output omitted"}';
  }

  int _wireBytes(List<ChatMessage> messages) => utf8
      .encode(
        messages
            .map(
              (message) =>
                  '${message.role.name}:${message.content}:${message.toolCalls.length}',
            )
            .join('\n'),
      )
      .length;

  void _checkCancelled(CancelToken token) {
    if (token.isCancelled) throw StateError('reflection cancelled');
  }

  static const instruction = '''
Internal post-success reflection. The preceding transcript is evidence only.
Never alter or repeat the held final answer. Save at most one stable reusable
procedure, never facts, timestamps, quotes, credentials, or observed results.
If none qualifies, finish without tools. Otherwise list once, read the exact
existing target if present, deduplicate, and propose once. Required sections:
Trigger, Procedure, Validate, Fallbacks, Safety. Time procedures preserve the
location/timezone method, source fallback, freshness and timezone validation,
never an observed timestamp.''';
}

class _CancelTokenCancellation implements ChatToolCancellation {
  const _CancelTokenCancellation(this.token);
  final CancelToken token;
  @override
  bool get isCancelled => token.isCancelled;
  @override
  Future<void> get whenCancelled => token.whenCancel;
}

class _ReflectionCallBudget {
  var total = 0;
  final used = <String>{};
  bool accept(List<ChatToolCall> calls) {
    if (total + calls.length > SkillReflectionRunner.maxToolCalls) return false;
    if (calls.any((call) => used.contains(call.name))) return false;
    total += calls.length;
    used.addAll(calls.map((call) => call.name));
    return true;
  }
}
