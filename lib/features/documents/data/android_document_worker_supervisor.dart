import 'package:flutter/services.dart';

import '../domain/document_limits.dart';
import '../domain/document_worker_supervisor.dart';

final class AndroidDocumentWorkerSupervisor
    implements DocumentWorkerSupervisor {
  AndroidDocumentWorkerSupervisor({
    MethodChannel channel = const MethodChannel('mobilka/document_worker'),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Set<DocumentWorkerCapability> get capabilities => const {};

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
        response.length != 4 ||
        response['version'] != 1 ||
        response['version'] is! int ||
        response['available'] != false ||
        response['capabilities'] is! List ||
        (response['capabilities'] as List).isNotEmpty ||
        response['reason'] != 'document_worker_unavailable') {
      throw const DocumentException('invalid_document_worker_capabilities');
    }
    throw const DocumentException('document_worker_unavailable');
  }

  @override
  DocumentWorkerHandle start(DocumentWorkerRequest request) {
    throw const DocumentException('document_worker_unavailable');
  }
}
