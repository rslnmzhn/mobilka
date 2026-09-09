import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/documents/data/android_document_worker_supervisor.dart';
import 'package:mobilka/features/documents/domain/document_limits.dart';
import 'package:mobilka/features/documents/domain/document_worker_supervisor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mobilka/document_worker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('capabilities are accepted only as a complete policy set', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      return <String, Object>{
        'version': 1,
        'available': true,
        'capabilities': DocumentWorkerCapability.values
            .map((value) => value.name)
            .toList(),
      };
    });
    final supervisor = AndroidDocumentWorkerSupervisor();
    await supervisor.checkAvailability();
    expect(supervisor.capabilities, DocumentWorkerCapability.values.toSet());
    expect(methods, ['capabilities']);
  });

  test(
    'malformed and prematurely enabled capability responses fail closed',
    () async {
      for (final response in <Object?>[
        null,
        [],
        {'version': 1},
        {
          'version': 1,
          'available': true,
          'capabilities': [],
          'reason': 'document_worker_unavailable',
        },
        {
          'version': 1,
          'available': false,
          'capabilities': ['nativeMemoryLimit'],
          'reason': 'document_worker_unavailable',
        },
        {
          'version': 1,
          'available': false,
          'capabilities': [],
          'reason': 'document_worker_unavailable',
          'extra': 1,
        },
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async => response);
        final supervisor = AndroidDocumentWorkerSupervisor();
        await expectLater(
          supervisor.checkAvailability(),
          throwsA(
            isA<DocumentException>().having(
              (e) => e.code,
              'code',
              'invalid_document_worker_capabilities',
            ),
          ),
        );
        expect(supervisor.capabilities, isEmpty);
      }
    },
  );

  test('missing native channel remains unavailable', () async {
    await expectLater(
      AndroidDocumentWorkerSupervisor().checkAvailability(),
      throwsA(isA<DocumentException>()),
    );
  });
}
