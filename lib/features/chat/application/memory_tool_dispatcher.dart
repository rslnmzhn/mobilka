import 'dart:convert';

import '../../../core/logging/app_logger.dart';
import '../../../features/memory/application/instant_memory_writer.dart';
import '../../../features/memory/application/persona_registry.dart';
import '../../../features/memory/domain/memory_file_names.dart';
import '../domain/chat_message.dart';
import '../domain/pending_memory_proposal.dart';
import 'chat_tool_runtime.dart';

class MemoryToolDispatchResult {
  const MemoryToolDispatchResult({this.proposal, this.result});

  final PendingMemoryProposal? proposal;
  final ChatMessage? result;
}

class MemoryToolDispatcher {
  const MemoryToolDispatcher({
    this.instantMemoryWriter,
    this.personaRegistry,
    this.logger,
  });

  final InstantMemoryWriter? instantMemoryWriter;
  final PersonaRegistryAdapter? personaRegistry;
  final AppLogger? logger;

  static const _configurationError = _SafeToolError(
    code: 'memory_unavailable',
    message: 'Memory storage is not configured.',
  );

  bool handles(ChatToolCall call) => const {
    'update_memory_file',
    'save_persona',
    'delete_persona',
  }.contains(call.name);

  Future<MemoryToolDispatchResult> dispatch({
    required ChatToolRuntime runtime,
    required ChatToolCall call,
    required String assistantId,
    required String? selectedAgentId,
    required Set<String> allowedTools,
    required int occurrence,
    required int resultIndex,
  }) async {
    var effectiveCall = call;
    if (call.name == 'save_persona' || call.name == 'delete_persona') {
      final registry = personaRegistry;
      if (registry == null) {
        return MemoryToolDispatchResult(
          result: _error(call, _configurationError, resultIndex),
        );
      }
      try {
        final args = call.arguments.trim().isEmpty
            ? const <String, Object?>{}
            : jsonDecode(call.arguments) as Map;
        final yaml = await registry.yamlAfter(
          operation: call.name,
          name: args['name']?.toString() ?? '',
          text: args['text']?.toString() ?? '',
        );
        effectiveCall = ChatToolCall(
          id: call.id,
          name: call.name,
          arguments: jsonEncode({
            'file_name': MemoryFiles.personas,
            'content': yaml,
          }),
        );
      } on FormatException catch (error) {
        final safe = _personaValidationError(error);
        _logFailure(call, safe, error);
        return MemoryToolDispatchResult(
          result: _error(call, safe, resultIndex),
        );
      } on Object catch (error) {
        const safe = _SafeToolError(
          code: 'persona_processing_failed',
          message: 'Persona data could not be processed.',
        );
        _logFailure(call, safe, error);
        return MemoryToolDispatchResult(
          result: _error(call, safe, resultIndex),
        );
      }
    }
    _MemoryToolArguments? memoryArguments;
    if (effectiveCall.name == 'update_memory_file') {
      try {
        memoryArguments = _MemoryToolArguments.decode(effectiveCall.arguments);
      } on FormatException catch (error) {
        final safe = _validationError(error);
        _logFailure(effectiveCall, safe, error);
        return MemoryToolDispatchResult(
          result: _error(effectiveCall, safe, resultIndex),
        );
      } on Object catch (error) {
        const safe = _SafeToolError(
          code: 'invalid_arguments',
          message: 'Memory tool arguments are invalid.',
        );
        _logFailure(effectiveCall, safe, error);
        return MemoryToolDispatchResult(
          result: _error(effectiveCall, safe, resultIndex),
        );
      }
    }
    if (memoryArguments?.fileName == MemoryFiles.memory) {
      final writer = instantMemoryWriter;
      if (writer == null) {
        return MemoryToolDispatchResult(
          result: _error(call, _configurationError, resultIndex),
        );
      }
      try {
        if (runtime is! MemoryProposalRuntime) {
          throw StateError('Memory permission runtime is unavailable.');
        }
        await (runtime as MemoryProposalRuntime).revalidateMemoryToolPermission(
          toolName: 'update_memory_file',
          selectedAgentId: selectedAgentId,
          allowedTools: allowedTools,
        );
        final note = await writer.write(memoryArguments!.content);
        return MemoryToolDispatchResult(
          result: _result(
            call,
            jsonEncode({
              'ok': true,
              'file': MemoryFiles.memory,
              'status': note,
            }),
            resultIndex,
          ),
        );
      } on Object catch (error) {
        final safe = error is StateError
            ? const _SafeToolError(
                code: 'permission_denied',
                message: 'Memory tool permission was denied.',
              )
            : const _SafeToolError(
                code: 'memory_write_failed',
                message: 'Memory could not be updated.',
              );
        _logFailure(call, safe, error);
        return MemoryToolDispatchResult(
          result: _error(call, safe, resultIndex),
        );
      }
    }
    try {
      if (runtime is! MemoryProposalRuntime) {
        throw StateError('Memory proposal runtime is unavailable.');
      }
      final proposal = await (runtime as MemoryProposalRuntime)
          .prepareMemoryProposal(
            effectiveCall,
            assistantId,
            selectedAgentId,
            allowedTools,
            occurrence,
          );
      if (proposal == null) {
        throw StateError('The memory proposal could not be prepared.');
      }
      return MemoryToolDispatchResult(proposal: proposal);
    } on Object catch (error) {
      const safe = _SafeToolError(
        code: 'proposal_failed',
        message: 'Memory proposal could not be prepared.',
      );
      _logFailure(effectiveCall, safe, error);
      return MemoryToolDispatchResult(
        result: _error(effectiveCall, safe, resultIndex),
      );
    }
  }

  _SafeToolError _validationError(FormatException error) {
    final message = error.message;
    final bounded = message.length <= 256
        ? message
        : '${message.substring(0, 253)}...';
    return _SafeToolError(code: 'validation_error', message: bounded);
  }

  _SafeToolError _personaValidationError(FormatException error) {
    const approved = {
      'Persona name must not be empty',
      'Cannot modify malformed personas.yaml',
      'Generated personas.yaml failed validation',
    };
    if (!approved.contains(error.message)) {
      return const _SafeToolError(
        code: 'persona_processing_failed',
        message: 'Persona data could not be processed.',
      );
    }
    return _validationError(error);
  }

  void _logFailure(ChatToolCall call, _SafeToolError safe, Object error) {
    logger?.log(
      event: 'memory.tool_dispatch',
      level: AppLogLevel.error,
      toolCallId: call.id,
      status: safe.code,
      error: error,
    );
  }

  ChatMessage _error(ChatToolCall call, _SafeToolError error, int index) =>
      _result(
        call,
        jsonEncode({
          'ok': false,
          'error_code': error.code,
          'error': error.message,
        }),
        index,
      );

  ChatMessage _result(ChatToolCall call, String content, int index) {
    final now = DateTime.now();
    return ChatMessage(
      id: '${now.microsecondsSinceEpoch}-tool-$index',
      role: ChatRole.tool,
      content: content,
      createdAt: now,
      toolCallId: call.id,
    );
  }
}

class _SafeToolError {
  const _SafeToolError({required this.code, required this.message});

  final String code;
  final String message;
}

class _MemoryToolArguments {
  const _MemoryToolArguments({required this.fileName, required this.content});

  factory _MemoryToolArguments.decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 2 ||
        !decoded.containsKey('file_name') ||
        !decoded.containsKey('content') ||
        decoded['file_name'] is! String ||
        decoded['content'] is! String) {
      throw const FormatException(
        'update_memory_file requires exactly string file_name and content arguments',
      );
    }
    return _MemoryToolArguments(
      fileName: decoded['file_name'] as String,
      content: decoded['content'] as String,
    );
  }

  final String fileName;
  final String content;
}
