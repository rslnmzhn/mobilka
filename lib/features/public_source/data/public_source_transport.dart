import 'dart:async';
import 'dart:io';

import '../../../core/logging/app_logger.dart';
import '../../chat/application/chat_tool_runtime.dart';
import '../application/public_source_policy.dart';
import 'public_source_secure_connector.dart';

export 'public_source_secure_connector.dart';

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

class PinnedPublicSourceTransport implements PublicSourceTransport {
  PinnedPublicSourceTransport({
    this.connector = const DirectPublicSourceConnector(),
    this.clientFactory = const IoNativePublicSourceClientFactory(),
    this.connectTimeout = const Duration(seconds: 8),
    AppLogger? logger,
  }) : logger = logger ?? AppLogger();
  final PublicSourceConnector connector;
  final NativePublicSourceClientFactory clientFactory;
  final Duration connectTimeout;
  final AppLogger logger;

  @override
  Future<PublicSourceResponse> open(
    ValidatedPublicTarget target, {
    ChatToolCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled == true) {
      throw const PublicSourceFailure('cancelled');
    }
    final client = clientFactory.create();
    final deadline = DateTime.now().add(connectTimeout);
    client.configure(
      autoUncompress: false,
      connectionTimeout: connectTimeout,
      findProxy: (_) => 'DIRECT',
      connectionFactory: (uri, proxyHost, proxyPort) async {
        if (proxyHost != null) {
          throw const PublicSourceFailure('network_failed');
        }
        if (uri.scheme != 'https') {
          throw const PublicSourceFailure('network_failed');
        }
        return _secureConnectionTask(target, uri.port, deadline, cancellation);
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

  ConnectionTask<Socket> _secureConnectionTask(
    ValidatedPublicTarget target,
    int port,
    DateTime deadline,
    ChatToolCancellation? cancellation,
  ) {
    ConnectionTask<Socket>? tcpTask;
    Socket? connectedSocket;
    var cancelled = false;

    Future<Socket> connect() async {
      Object? lastError;
      for (final candidate in target.addresses.indexed) {
        var connected = false;
        var attemptAbandoned = false;
        if (cancelled || cancellation?.isCancelled == true) {
          throw const PublicSourceFailure('cancelled');
        }
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          throw const PublicSourceFailure('timeout');
        }
        final family = candidate.$2.type == InternetAddressType.IPv6
            ? 'ipv6'
            : 'ipv4';
        logger.log(
          event: 'public_source.connect',
          status:
              'tcp.$family.${candidate.$1 + 1}.${target.addresses.length}.start',
        );
        try {
          final pendingTask = connector.connect(
            candidate.$2,
            port,
            host: target.uri.host,
          );
          final ownedTask = pendingTask.then((task) {
            if (cancelled || attemptAbandoned) {
              task.cancel();
              task.socket.then((socket) => socket.destroy(), onError: (_) {});
              throw const PublicSourceFailure('cancelled');
            }
            tcpTask = task;
            return task;
          });
          tcpTask = await _withDeadline(ownedTask, deadline, cancellation);
          final secure = await _withDeadline(
            tcpTask!.socket,
            deadline,
            cancellation,
          );
          connectedSocket = secure;
          logger.log(
            event: 'public_source.connect',
            status:
                'tls.$family.${candidate.$1 + 1}.${target.addresses.length}.ok',
          );
          connected = true;
          return secure;
        } on PublicSourceFailure catch (error) {
          attemptAbandoned = true;
          connectedSocket?.destroy();
          tcpTask?.cancel();
          if (error.code == 'cancelled' || error.code == 'timeout') rethrow;
          lastError = error;
        } on Object catch (error) {
          attemptAbandoned = true;
          lastError = error;
          connectedSocket?.destroy();
          tcpTask?.cancel();
          logger.log(
            event: 'public_source.connect',
            level: AppLogLevel.warning,
            status:
                'candidate.$family.${candidate.$1 + 1}.${target.addresses.length}.failed',
            error: error,
          );
        } finally {
          if (!connected) {
            connectedSocket = null;
            tcpTask = null;
          }
        }
      }
      logger.log(
        event: 'public_source.connect',
        level: AppLogLevel.warning,
        status: 'all_candidates.failed',
        error: lastError,
      );
      throw const PublicSourceFailure('network_failed');
    }

    return ConnectionTask.fromSocket(connect(), () async {
      cancelled = true;
      connectedSocket?.destroy();
      tcpTask?.cancel();
    });
  }

  Future<T> _withDeadline<T>(
    Future<T> operation,
    DateTime deadline,
    ChatToolCancellation? cancellation,
  ) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw const PublicSourceFailure('timeout');
    }
    return _race(
      operation.timeout(
        remaining,
        onTimeout: () => throw const PublicSourceFailure('timeout'),
      ),
      cancellation,
    );
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
