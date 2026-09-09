import 'dart:async';

import 'package:flutter/services.dart';

import 'document_worker_protocol.dart';
import '../domain/document_limits.dart';
import '../domain/document_worker_supervisor.dart';

final class AndroidDocumentWorkerSupervisor
    implements DocumentWorkerSupervisor {
  AndroidDocumentWorkerSupervisor({
    MethodChannel channel = const MethodChannel('mobilka/document_worker'),
    EventChannel events = const EventChannel('mobilka/document_worker/events'),
  }) : _channel = channel,
       _events = events;

  final MethodChannel _channel;
  final EventChannel _events;
  Set<DocumentWorkerCapability> _capabilities = const {};

  @override
  Set<DocumentWorkerCapability> get capabilities => _capabilities;

  Future<void> checkAvailability() async {
    final Object? response;
    try {
      response = await _channel.invokeMethod<Object?>('capabilities');
    } on MissingPluginException {
      throw const DocumentException('document_worker_unavailable');
    } on PlatformException {
      throw const DocumentException('document_worker_unavailable');
    }
    if (response is! Map ||
        response.length != 3 ||
        response['version'] != 1 ||
        response['version'] is! int ||
        response['available'] != true ||
        response['capabilities'] is! List ||
        (response['capabilities'] as List).any((value) => value is! String)) {
      throw const DocumentException('invalid_document_worker_capabilities');
    }
    final names = (response['capabilities'] as List).cast<String>().toSet();
    final parsed = <DocumentWorkerCapability>{};
    for (final capability in DocumentWorkerCapability.values) {
      if (names.remove(capability.name)) parsed.add(capability);
    }
    if (names.isNotEmpty ||
        !parsed.containsAll(DocumentWorkerCapability.values)) {
      throw const DocumentException('invalid_document_worker_capabilities');
    }
    _capabilities = Set.unmodifiable(parsed);
  }

  @override
  DocumentWorkerHandle start(DocumentWorkerRequest request) {
    if (!_capabilities.containsAll(DocumentWorkerCapability.values)) {
      throw const DocumentException('document_worker_unavailable');
    }
    return _AndroidDocumentWorkerHandle(
      request: request,
      channel: _channel,
      events: _events,
    );
  }
}

final class _AndroidDocumentWorkerHandle implements DocumentWorkerHandle {
  _AndroidDocumentWorkerHandle({
    required this.request,
    required MethodChannel channel,
    required EventChannel events,
  }) : _channel = channel,
       _events = events;

  final DocumentWorkerRequest request;
  final MethodChannel _channel;
  final EventChannel _events;
  bool _started = false;
  Future<void>? _termination;

  @override
  String get jobId => request.jobId;

  @override
  Stream<List<int>> get output async* {
    if (_started) throw const DocumentException('document_worker_busy');
    _started = true;
    final stream = _events.receiveBroadcastStream(jobId).map<List<int>>((
      event,
    ) {
      if (event is Uint8List &&
          event.length <= DocumentWorkerProtocol.maxChunkBytes) {
        return event;
      }
      throw const DocumentException('invalid_document_worker_protocol');
    });
    late StreamSubscription<List<int>> subscription;
    final controller = StreamController<List<int>>();
    subscription = stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    await Future<void>.delayed(Duration.zero);
    try {
      await _channel.invokeMethod<void>('start', <String, Object>{
        'jobId': jobId,
        'request': DocumentWorkerProtocol.encodeRequest(request),
      });
      yield* controller.stream;
    } on PlatformException catch (error) {
      throw DocumentException(error.code);
    } finally {
      await subscription.cancel();
      await controller.close();
    }
  }

  @override
  Future<void> terminateAndReap() => _termination ??= _terminate();

  Future<void> _terminate() async {
    try {
      await _channel.invokeMethod<void>('cancel', <String, Object>{
        'jobId': jobId,
      });
    } on PlatformException catch (error) {
      if (error.code != 'document_worker_not_running') {
        throw DocumentException(error.code);
      }
    }
  }

  @override
  Future<void> cleanup() async {}
}
