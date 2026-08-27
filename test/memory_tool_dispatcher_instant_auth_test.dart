import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart';
import 'package:mobilka/features/chat/application/memory_tool_dispatcher.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/chat_tool.dart';
import 'package:mobilka/features/chat/domain/pending_memory_proposal.dart';
import 'package:mobilka/features/memory/application/instant_memory_writer.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';

void main() {
  late _Boundary boundary;
  late MemoryToolDispatcher dispatcher;

  setUp(() {
    boundary = _Boundary({'memory.md': '# Memory\n'});
    dispatcher = MemoryToolDispatcher(
      instantMemoryWriter: InstantMemoryWriter(
        MemoryMutationCoordinator(boundary),
      ),
    );
  });

  test('instant memory rejects missing request snapshot permission', () async {
    final result = await _dispatch(dispatcher, _PermissionRuntime(), const {});

    expect(jsonDecode(result.result!.content)['ok'], isFalse);
    expect(boundary.files['memory.md'], '# Memory\n');
  });

  test(
    'instant memory rejects permission revoked from current agent',
    () async {
      final result = await _dispatch(
        dispatcher,
        _PermissionRuntime(currentlyAllowed: false),
        const {'update_memory_file'},
      );

      expect(jsonDecode(result.result!.content)['ok'], isFalse);
      expect(boundary.files['memory.md'], '# Memory\n');
    },
  );

  test(
    'instant memory writes when snapshot and current permission agree',
    () async {
      final result = await _dispatch(dispatcher, _PermissionRuntime(), const {
        'update_memory_file',
      });

      expect(jsonDecode(result.result!.content)['ok'], isTrue);
      expect(boundary.files['memory.md'], startsWith('# Updated\n'));
      expect(boundary.writeCalls, greaterThan(0));
    },
  );

  final malformedArguments = <String, String>{
    'missing content': '{"file_name":"memory.md"}',
    'null content': '{"file_name":"memory.md","content":null}',
    'non-string content': '{"file_name":"memory.md","content":42}',
    'non-string file_name': '{"file_name":42,"content":"# Updated\\n"}',
    'extra fields':
        '{"file_name":"memory.md","content":"# Updated\\n","extra":true}',
  };
  for (final entry in malformedArguments.entries) {
    test('instant memory rejects ${entry.key} without writing', () async {
      final runtime = _PermissionRuntime();

      final result = await _dispatch(dispatcher, runtime, const {
        'update_memory_file',
      }, arguments: entry.value);

      expect(jsonDecode(result.result!.content)['ok'], isFalse);
      expect(boundary.files['memory.md'], '# Memory\n');
      expect(boundary.writeCalls, 0);
      expect(runtime.revalidationCalls, 0);
    });
  }
}

Future<MemoryToolDispatchResult> _dispatch(
  MemoryToolDispatcher dispatcher,
  ChatToolRuntime runtime,
  Set<String> allowedTools, {
  String arguments = '{"file_name":"memory.md","content":"# Updated\\n"}',
}) => dispatcher.dispatch(
  runtime: runtime,
  call: ChatToolCall(
    id: 'call-1',
    name: 'update_memory_file',
    arguments: arguments,
  ),
  assistantId: 'assistant-1',
  selectedAgentId: 'agent-1',
  allowedTools: allowedTools,
  occurrence: 0,
  resultIndex: 0,
);

class _PermissionRuntime implements ChatToolRuntime, MemoryProposalRuntime {
  _PermissionRuntime({this.currentlyAllowed = true});

  final bool currentlyAllowed;
  int revalidationCalls = 0;

  @override
  Future<void> revalidateMemoryToolPermission({
    required String toolName,
    required String? selectedAgentId,
    required Set<String> allowedTools,
  }) async {
    revalidationCalls++;
    if (!allowedTools.contains(toolName)) throw StateError('snapshot denied');
    if (!currentlyAllowed) throw StateError('current agent denied');
  }

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async => const [];

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools,
  ) async => '{}';

  @override
  Future<PendingMemoryProposal?> prepareMemoryProposal(
    ChatToolCall call,
    String assistantMessageId,
    String? selectedAgentId,
    Set<String> allowedTools, [
    int callOccurrence = 0,
  ]) async => null;

  @override
  Future<void> revalidateMemoryProposal(PendingMemoryProposal proposal) async {}
}

class _Boundary implements MemoryFileBoundary, MemoryFileTransaction {
  _Boundary(this.files);

  final Map<String, String> files;
  int writeCalls = 0;

  @override
  Future<T> transaction<T>(Future<T> Function(MemoryFileTransaction) action) =>
      action(this);

  @override
  Future<String> read(String fileName) async => files[fileName]!;

  @override
  Future<void> write(String fileName, String content) async {
    writeCalls++;
    files[fileName] = content;
  }

  @override
  Future<void> delete(String fileName) async {
    files.remove(fileName);
  }
}
