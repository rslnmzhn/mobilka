import 'dart:async';
import 'package:flutter/services.dart';

import '../domain/document_limits.dart';
import '../domain/document_worker_supervisor.dart';
import 'document_worker_protocol.dart';

final class WindowsDocumentWorkerSupervisor
    implements DocumentWorkerSupervisor {
  WindowsDocumentWorkerSupervisor({
    MethodChannel channel = const MethodChannel('mobilka/document_worker'),
  }) : _channel = channel;
  final MethodChannel _channel;
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
        response['version'] != DocumentWorkerProtocol.version ||
        response['available'] != true ||
        response['capabilities'] is! List ||
        (response['capabilities'] as List).any((value) => value is! String)) {
      throw const DocumentException('document_worker_unavailable');
    }
    final names = (response['capabilities'] as List).cast<String>().toSet();
    final required = DocumentWorkerCapability.values
        .map((value) => value.name)
        .toSet();
    if (names.length != required.length || !names.containsAll(required)) {
      throw const DocumentException('document_worker_unavailable');
    }
    _capabilities = Set.unmodifiable(DocumentWorkerCapability.values);
  }

  @override
  DocumentWorkerHandle start(DocumentWorkerRequest request) {
    if (!_capabilities.containsAll(DocumentWorkerCapability.values)) {
      throw const DocumentException('document_worker_unavailable');
    }
    return _WindowsHandle(
      _channel,
      request.jobId,
      DocumentWorkerProtocol.encodeRequest(request),
    );
  }
}

final class _WindowsHandle implements DocumentWorkerHandle {
  _WindowsHandle(this._channel, this.jobId, Uint8List request) {
    scheduleMicrotask(() async {
      try {
        final response = await _channel.invokeMethod<Uint8List>('run', request);
        if (response == null ||
            response.length > DocumentLimits().outputBytes) {
          throw const DocumentException('document_worker_output_limit');
        }
        for (
          var offset = 0;
          offset < response.length;
          offset += DocumentWorkerProtocol.maxChunkBytes
        ) {
          _output.add(
            response.sublist(
              offset,
              (offset + DocumentWorkerProtocol.maxChunkBytes).clamp(
                0,
                response.length,
              ),
            ),
          );
        }
      } on PlatformException catch (error, stack) {
        _output.addError(DocumentException(error.code), stack);
      } catch (error, stack) {
        _output.addError(error, stack);
      } finally {
        await _output.close();
        _reaped.complete();
      }
    });
  }
  final MethodChannel _channel;
  @override
  final String jobId;
  final StreamController<List<int>> _output = StreamController();
  final Completer<void> _reaped = Completer();
  @override
  Stream<List<int>> get output => _output.stream;
  @override
  Future<void> terminateAndReap() async {
    try {
      await _channel.invokeMethod<void>('terminate');
    } on PlatformException {
      throw const DocumentException('document_worker_termination_failed');
    }
    await _reaped.future;
  }

  @override
  Future<void> cleanup() async {
    if (!_reaped.isCompleted) await terminateAndReap();
  }
}
