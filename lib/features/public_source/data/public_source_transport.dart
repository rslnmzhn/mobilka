import 'dart:async';
import 'dart:io';

import '../../chat/application/chat_tool_runtime.dart';
import '../application/public_source_policy.dart';

const publicSourceTransferLimit = 1024 * 1024;

abstract interface class PublicSourceResponse {
  int get status;
  int get contentLength;
  Map<String, String> get headers;
  Stream<List<int>> get body;
  void abort();
}

abstract interface class PublicSourceTransport {
  Future<PublicSourceResponse> open(
    ValidatedPublicTarget target, {
    ChatToolCancellation? cancellation,
  });
}

abstract interface class PublicSourceConnector {
  Future<ConnectionTask<Socket>> connect(InternetAddress address, int port);
}

typedef PublicSourceConnectionFactory =
    Future<ConnectionTask<Socket>> Function(
      Uri uri,
      String? proxyHost,
      int? proxyPort,
    );

abstract interface class NativePublicSourceClient {
  void configure({
    required bool autoUncompress,
    required Duration connectionTimeout,
    required String Function(Uri uri) findProxy,
    required PublicSourceConnectionFactory connectionFactory,
  });
  Future<NativePublicSourceRequest> open(Uri uri);
  void close({required bool force});
}

abstract interface class NativePublicSourceRequest {
  void configure({
    required bool followRedirects,
    required int maxRedirects,
    required Map<String, String> headers,
  });
  Future<PublicSourceResponse> close(NativePublicSourceClient client);
  void abort();
}

abstract interface class NativePublicSourceClientFactory {
  NativePublicSourceClient create();
}

class IoNativePublicSourceClientFactory
    implements NativePublicSourceClientFactory {
  const IoNativePublicSourceClientFactory();
  @override
  NativePublicSourceClient create() => _IoNativeClient();
}

class DirectPublicSourceConnector implements PublicSourceConnector {
  const DirectPublicSourceConnector();
  @override
  Future<ConnectionTask<Socket>> connect(InternetAddress address, int port) =>
      Socket.startConnect(address, port);
}

class PinnedPublicSourceTransport implements PublicSourceTransport {
  const PinnedPublicSourceTransport({
    this.connector = const DirectPublicSourceConnector(),
    this.clientFactory = const IoNativePublicSourceClientFactory(),
    this.connectTimeout = const Duration(seconds: 8),
  });
  final PublicSourceConnector connector;
  final NativePublicSourceClientFactory clientFactory;
  final Duration connectTimeout;

  @override
  Future<PublicSourceResponse> open(
    ValidatedPublicTarget target, {
    ChatToolCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled == true) {
      throw const PublicSourceFailure('cancelled');
    }
    final client = clientFactory.create();
    client.configure(
      autoUncompress: false,
      connectionTimeout: connectTimeout,
      findProxy: (_) => 'DIRECT',
      connectionFactory: (uri, proxyHost, proxyPort) {
        if (proxyHost != null) {
          throw const PublicSourceFailure('network_failed');
        }
        return connector.connect(target.addresses.first, uri.port);
      },
    );
    NativePublicSourceRequest? request;
    try {
      final opened = await _race(client.open(target.uri), cancellation);
      request = opened;
      opened.configure(
        followRedirects: false,
        maxRedirects: 0,
        headers: const {
          'accept': 'text/*, application/json, application/xml',
          'accept-encoding': 'identity',
          'user-agent': 'mobilka-public-source/1',
        },
      );
      final response = await _race(opened.close(client), cancellation);
      cancellation?.whenCancelled.then((_) => response.abort()).ignore();
      return response;
    } on PublicSourceFailure {
      request?.abort();
      client.close(force: true);
      rethrow;
    } on Object {
      request?.abort();
      client.close(force: true);
      throw const PublicSourceFailure('network_failed');
    }
  }

  Future<T> _race<T>(Future<T> operation, ChatToolCancellation? cancellation) {
    if (cancellation == null) return operation;
    return Future.any([
      operation,
      cancellation.whenCancelled.then<T>((_) {
        throw const PublicSourceFailure('cancelled');
      }),
    ]);
  }
}

class _IoNativeClient implements NativePublicSourceClient {
  final HttpClient _client = HttpClient(
    context: SecurityContext.defaultContext,
  );

  @override
  void configure({
    required bool autoUncompress,
    required Duration connectionTimeout,
    required String Function(Uri uri) findProxy,
    required PublicSourceConnectionFactory connectionFactory,
  }) {
    _client
      ..autoUncompress = autoUncompress
      ..connectionTimeout = connectionTimeout
      ..findProxy = findProxy
      ..connectionFactory = connectionFactory;
  }

  @override
  Future<NativePublicSourceRequest> open(Uri uri) async =>
      _IoNativeRequest(await _client.getUrl(uri));

  @override
  void close({required bool force}) => _client.close(force: force);
}

class _IoNativeRequest implements NativePublicSourceRequest {
  _IoNativeRequest(this._request);
  final HttpClientRequest _request;

  @override
  void configure({
    required bool followRedirects,
    required int maxRedirects,
    required Map<String, String> headers,
  }) {
    _request
      ..followRedirects = followRedirects
      ..maxRedirects = maxRedirects;
    for (final entry in headers.entries) {
      _request.headers.set(entry.key, entry.value);
    }
  }

  @override
  Future<PublicSourceResponse> close(NativePublicSourceClient client) async =>
      _IoPublicSourceResponse(
        await _request.close(),
        (client as _IoNativeClient)._client,
      );

  @override
  void abort() => _request.abort();
}

class _IoPublicSourceResponse implements PublicSourceResponse {
  _IoPublicSourceResponse(this._response, this._client);
  final HttpClientResponse _response;
  final HttpClient _client;
  var _closed = false;

  @override
  int get status => _response.statusCode;
  @override
  int get contentLength => _response.contentLength;
  @override
  Stream<List<int>> get body => _response;
  @override
  Map<String, String> get headers {
    final result = <String, String>{};
    _response.headers.forEach(
      (name, values) => result[name.toLowerCase()] = values.join(','),
    );
    return result;
  }

  @override
  void abort() {
    if (_closed) return;
    _closed = true;
    _response.detachSocket().then((socket) => socket.destroy()).ignore();
    _client.close(force: true);
  }
}
