import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/memory/application/prompt_guard.dart';
import 'package:mobilka/features/public_source/application/public_source_chat_tool_runtime.dart';
import 'package:mobilka/features/public_source/application/public_source_policy.dart';
import 'package:mobilka/features/public_source/application/public_source_reader.dart';
import 'package:mobilka/features/public_source/data/public_source_transport.dart';

void main() {
  late PublicSourceChatToolRuntime runtime;
  late _Cancellation cancellation;
  setUp(() {
    cancellation = _Cancellation();
    runtime = PublicSourceChatToolRuntime(
      reader: PublicSourceReader(
        policy: PublicSourcePolicy(_Resolver()),
        transport: _Transport(),
        guard: const PromptGuard(),
      ),
    );
  });

  test('schema and allowlist are strict', () async {
    final tools = await runtime.availableTools(const {'read_public_source'});
    expect(tools, hasLength(1));
    expect(tools.single.parameters['additionalProperties'], isFalse);
    expect(await runtime.availableTools(const {}), isEmpty);
    await expectLater(
      runtime.executeTool(_call('{}'), const {}),
      throwsStateError,
    );
  });

  for (final arguments in [
    '{}',
    '{"url":"https://example.com","extra":1}',
    '{"url":"https://example.com","offset":1.5}',
    '{"url":"https://example.com","offset":-1}',
    '{"url":"https://example.com","offset":1048577}',
  ]) {
    test('rejects arguments $arguments', () async {
      final output =
          jsonDecode(
                await runtime.executeTool(_call(arguments), const {
                  'read_public_source',
                }, context: _context(cancellation)),
              )
              as Map;
      expect(output['ok'], isFalse);
      expect(output['error_code'], isNotNull);
    });
  }

  test('requires immutable context and propagates cancellation', () async {
    final missing =
        jsonDecode(
              await runtime.executeTool(
                _call('{"url":"https://example.com"}'),
                const {'read_public_source'},
              ),
            )
            as Map;
    expect(missing['error_code'], 'missing_context');

    cancellation.cancel();
    final cancelled =
        jsonDecode(
              await runtime.executeTool(
                _call('{"url":"https://example.com"}'),
                const {'read_public_source'},
                context: _context(cancellation),
              ),
            )
            as Map;
    expect(cancelled, {'ok': false, 'error_code': 'cancelled'});
  });
}

ChatToolCall _call(String arguments) =>
    ChatToolCall(id: 'call', name: 'read_public_source', arguments: arguments);

ChatToolExecutionContext _context(ChatToolCancellation cancellation) =>
    ChatToolExecutionContext(
      conversationId: 'conversation',
      sessionKey: 'session',
      cancellation: cancellation,
    );

class _Resolver implements PublicSourceResolver {
  @override
  Future<List<InternetAddress>> resolve(String host) async => [
    InternetAddress('93.184.216.34'),
  ];
}

class _Transport implements PublicSourceTransport {
  @override
  Future<PublicSourceResponse> open(
    ValidatedPublicTarget target, {
    ChatToolCancellation? cancellation,
  }) async => _Response();
}

class _Response implements PublicSourceResponse {
  @override
  int get status => 200;
  @override
  int get contentLength => 0;
  @override
  Map<String, String> get headers => const {'content-type': 'text/plain'};
  @override
  Stream<List<int>> get body => const Stream.empty();
  @override
  void abort() {}
}

class _Cancellation implements ChatToolCancellation {
  final value = Completer<void>();
  @override
  bool get isCancelled => value.isCompleted;
  @override
  Future<void> get whenCancelled => value.future;
  void cancel() => value.complete();
}
