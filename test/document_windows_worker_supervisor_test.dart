import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/documents/data/windows_document_worker_supervisor.dart';
import 'package:mobilka/features/documents/domain/document_limits.dart';
import 'package:mobilka/features/documents/domain/document_worker_supervisor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mobilka/document_worker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('enables only the complete verified broker capability policy', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => <String, Object>{
        'version': 1,
        'available': true,
        'capabilities': DocumentWorkerCapability.values
            .map((value) => value.name)
            .toList(),
      },
    );
    final supervisor = WindowsDocumentWorkerSupervisor();
    await supervisor.checkAvailability();
    expect(supervisor.capabilities, DocumentWorkerCapability.values.toSet());
  });

  test('fails closed for incomplete capability policy', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => <String, Object>{
        'version': 1,
        'available': true,
        'capabilities': <String>[],
      },
    );
    final supervisor = WindowsDocumentWorkerSupervisor();
    await expectLater(
      supervisor.checkAvailability(),
      throwsA(isA<DocumentException>()),
    );
    expect(supervisor.capabilities, isEmpty);
  });

  test('sends bounded binary request and returns worker frames', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'capabilities') {
        return <String, Object>{
          'version': 1,
          'available': true,
          'capabilities': DocumentWorkerCapability.values
              .map((value) => value.name)
              .toList(),
        };
      }
      if (call.method == 'terminate') return null;
      expect(call.arguments, isA<Uint8List>());
      return Uint8List.fromList([0, 0, 0, 47, 1, 2, ...List.filled(45, 0)]);
    });
    final supervisor = WindowsDocumentWorkerSupervisor();
    await supervisor.checkAvailability();
    final request = DocumentWorkerRequest(
      jobId: List.filled(16, '00').join(),
      bytes: Uint8List.fromList([1]),
      sourceHash: sha256.convert([1]).toString(),
      options: DocumentWorkerOptions(
        operation: DocumentWorkerOperation.imageOcr,
      ),
      limits: DocumentLimits(),
    );
    final handle = supervisor.start(request);
    expect(await handle.output.single, hasLength(51));
    await handle.cleanup();
    expect(methods, ['capabilities', 'run', 'terminate']);
  });
}
