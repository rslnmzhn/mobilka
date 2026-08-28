import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/chat_tool_runtime.dart';
import 'package:mobilka/features/public_source/application/public_source_policy.dart';
import 'package:mobilka/features/public_source/data/public_source_transport.dart';

void main() {
  test(
    'production configuration pins numeric address and sends fixed metadata',
    () async {
      final native = _NativeClient();
      final connector = _Connector();
      final transport = PinnedPublicSourceTransport(
        connector: connector,
        clientFactory: _Factory(native),
      );
      final resolver = _Resolver();
      final target = await PublicSourcePolicy(
        resolver,
      ).validate('https://source.example/path?q=1');

      final response = await transport.open(target);

      expect(native.openedUri, target.uri);
      expect(native.autoUncompress, isFalse);
      expect(native.proxy!(target.uri), 'DIRECT');
      expect(native.request.followRedirects, isFalse);
      expect(native.request.maxRedirects, 0);
      expect(native.request.headers, {
        'accept': 'text/*, application/json, application/xml',
        'accept-encoding': 'identity',
        'user-agent': 'mobilka-public-source/1',
      });
      for (final forbidden in [
        'authorization',
        'cookie',
        'proxy-authorization',
        'referer',
        'chat',
      ]) {
        expect(native.request.headers, isNot(contains(forbidden)));
      }
      await expectLater(
        native.connectionFactory!(target.uri, null, null),
        throwsA(isA<PublicSourceFailure>()),
      );
      expect(connector.address?.address, '93.184.216.34');
      expect(connector.port, 443);
      expect(connector.calls, 1);
      expect(resolver.calls, 1);
      response.abort();
      expect(native.closed, isTrue);
    },
  );

  test('cancellation aborts pending native request and client', () async {
    final native = _NativeClient(closePending: true);
    final cancellation = _Cancellation();
    final future = PinnedPublicSourceTransport(clientFactory: _Factory(native))
        .open(
          ValidatedPublicTarget(Uri.parse('https://source.example/'), [
            InternetAddress('93.184.216.34'),
          ]),
          cancellation: cancellation,
        );
    await Future<void>.delayed(Duration.zero);
    cancellation.cancel();

    await expectLater(
      future,
      throwsA(
        isA<PublicSourceFailure>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );
    expect(native.request.aborted, isTrue);
    expect(native.closed, isTrue);
  });

  test('cancellation after open aborts response stream and client', () async {
    final native = _NativeClient();
    final cancellation = _Cancellation();
    final response =
        await PinnedPublicSourceTransport(clientFactory: _Factory(native)).open(
          ValidatedPublicTarget(Uri.parse('https://source.example/'), [
            InternetAddress('93.184.216.34'),
          ]),
          cancellation: cancellation,
        );
    cancellation.cancel();
    await Future<void>.delayed(Duration.zero);
    expect((response as _Response).aborted, isTrue);
    expect(native.closed, isTrue);
  });
}

class _Resolver implements PublicSourceResolver {
  int calls = 0;
  @override
  Future<List<InternetAddress>> resolve(String host) async {
    calls++;
    expect(host, 'source.example');
    return [InternetAddress('93.184.216.34')];
  }
}

class _Factory implements NativePublicSourceClientFactory {
  const _Factory(this.client);
  final NativePublicSourceClient client;
  @override
  NativePublicSourceClient create() => client;
}

class _NativeClient implements NativePublicSourceClient {
  _NativeClient({this.closePending = false});
  final bool closePending;
  final request = _Request();
  bool? autoUncompress;
  bool closed = false;
  Uri? openedUri;
  String Function(Uri)? proxy;
  PublicSourceConnectionFactory? connectionFactory;

  @override
  void configure({
    required bool autoUncompress,
    required Duration connectionTimeout,
    required String Function(Uri uri) findProxy,
    required PublicSourceConnectionFactory connectionFactory,
  }) {
    this.autoUncompress = autoUncompress;
    proxy = findProxy;
    this.connectionFactory = connectionFactory;
    request.closePending = closePending;
  }

  @override
  Future<NativePublicSourceRequest> open(Uri uri) async {
    openedUri = uri;
    return request;
  }

  @override
  void close({required bool force}) => closed = force;
}

class _Request implements NativePublicSourceRequest {
  bool followRedirects = true;
  int maxRedirects = -1;
  Map<String, String> headers = {};
  bool aborted = false;
  bool closePending = false;

  @override
  void configure({
    required bool followRedirects,
    required int maxRedirects,
    required Map<String, String> headers,
  }) {
    this.followRedirects = followRedirects;
    this.maxRedirects = maxRedirects;
    this.headers = headers;
  }

  @override
  Future<PublicSourceResponse> close(NativePublicSourceClient client) {
    if (closePending) return Completer<PublicSourceResponse>().future;
    return Future.value(_Response(() => client.close(force: true)));
  }

  @override
  void abort() => aborted = true;
}

class _Response implements PublicSourceResponse {
  _Response(this.onAbort);
  final void Function() onAbort;
  bool aborted = false;
  @override
  int get status => 200;
  @override
  int get contentLength => 0;
  @override
  Map<String, String> get headers => const {'content-type': 'text/plain'};
  @override
  Stream<List<int>> get body => const Stream.empty();
  @override
  void abort() {
    aborted = true;
    onAbort();
  }
}

class _Connector implements PublicSourceConnector {
  InternetAddress? address;
  int? port;
  int calls = 0;
  @override
  Future<ConnectionTask<Socket>> connect(
    InternetAddress address,
    int port,
  ) async {
    this.address = address;
    this.port = port;
    calls++;
    throw const PublicSourceFailure('test_stop');
  }
}

class _Cancellation implements ChatToolCancellation {
  final _value = Completer<void>();
  @override
  bool get isCancelled => _value.isCompleted;
  @override
  Future<void> get whenCancelled => _value.future;
  void cancel() => _value.complete();
}
