import 'dart:async';
import 'dart:io';

import '../../chat/application/chat_tool_runtime.dart';
import '../../public_source/application/public_source_policy.dart';
import '../../public_source/data/public_source_secure_connector.dart';
import '../application/web_search_policy.dart';

class SearxngResponse {
  const SearxngResponse(this.status, this.headers, this.body, [this.abort]);
  final int status;
  final Map<String, String> headers;
  final Stream<List<int>> body;
  final Future<void> Function()? abort;
}

abstract interface class SearxngTransport {
  Future<SearxngResponse> get(
    ValidatedPublicTarget target, {
    required Map<String, String> headers,
    required ChatToolCancellation cancellation,
  });
}

class DirectSearxngTransport implements SearxngTransport {
  const DirectSearxngTransport({
    this.connector = const DirectPublicSourceConnector(),
    this.connectTimeout = const Duration(seconds: 8),
  });
  final PublicSourceConnector connector;
  final Duration connectTimeout;

  @override
  Future<SearxngResponse> get(
    ValidatedPublicTarget target, {
    required Map<String, String> headers,
    required ChatToolCancellation cancellation,
  }) async {
    if (cancellation.isCancelled) {
      throw const WebSearchFailure('cancelled');
    }
    final client = HttpClient(context: SecurityContext.defaultContext)
      ..autoUncompress = false
      ..connectionTimeout = connectTimeout
      ..findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (proxyHost != null) throw const WebSearchFailure('network_failed');
      return _connection(target, uri.port, cancellation);
    };
    HttpClientRequest? request;
    try {
      final opened = await _race(client.getUrl(target.uri), cancellation);
      request = opened;
      opened
        ..followRedirects = false
        ..maxRedirects = 0;
      headers.forEach(opened.headers.set);
      final response = await _race(opened.close(), cancellation);
      cancellation.whenCancelled.then((_) {
        response.detachSocket().then((socket) => socket.destroy()).ignore();
        client.close(force: true);
      }).ignore();
      final resultHeaders = <String, String>{};
      response.headers.forEach(
        (name, values) => resultHeaders[name.toLowerCase()] = values.join(','),
      );
      return SearxngResponse(
        response.statusCode,
        resultHeaders,
        response,
        () async {
          try {
            final socket = await response.detachSocket();
            socket.destroy();
          } on Object {
            // The response may already have been detached by cancellation.
          }
          client.close(force: true);
        },
      );
    } on WebSearchFailure {
      request?.abort();
      client.close(force: true);
      rethrow;
    } on Object {
      request?.abort();
      client.close(force: true);
      throw const WebSearchFailure('network_failed');
    }
  }

  Future<ConnectionTask<Socket>> _connection(
    ValidatedPublicTarget target,
    int port,
    ChatToolCancellation cancellation,
  ) async {
    ConnectionTask<Socket>? active;
    Socket? connected;
    var stopped = false;
    cancellation.whenCancelled.then((_) {
      stopped = true;
      active?.cancel();
      connected?.destroy();
    }).ignore();
    Future<Socket> connect() async {
      Object? last;
      for (final address in target.addresses) {
        if (stopped || cancellation.isCancelled) {
          throw const WebSearchFailure('cancelled');
        }
        try {
          active = target.uri.scheme == 'https'
              ? await connector.connect(address, port, host: target.uri.host)
              : await Socket.startConnect(address, port);
          final socket = await _race(active!.socket, cancellation);
          if (stopped) {
            socket.destroy();
            throw const WebSearchFailure('cancelled');
          }
          connected = socket;
          return socket;
        } on WebSearchFailure catch (error) {
          active?.cancel();
          if (error.code == 'cancelled') rethrow;
          last = error;
        } on Object catch (error) {
          active?.cancel();
          last = error;
        }
      }
      throw WebSearchFailure(
        last is TimeoutException ? 'timeout' : 'network_failed',
      );
    }

    return ConnectionTask.fromSocket(connect(), () async {
      stopped = true;
      active?.cancel();
      connected?.destroy();
    });
  }

  Future<T> _race<T>(Future<T> operation, ChatToolCancellation cancellation) {
    return Future.any([
      operation,
      cancellation.whenCancelled.then<T>(
        (_) => throw const WebSearchFailure('cancelled'),
      ),
    ]);
  }
}
