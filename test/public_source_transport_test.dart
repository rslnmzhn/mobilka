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
      expect(native.connectionFactory, isNotNull);
      expect(connector.calls, 0);
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

  test(
    'connection seam upgrades with original host and falls back in order',
    () async {
      final native = _NativeClient();
      final connector = _SequenceConnector([
        StateError('ipv6 failed'),
        _FakeSocket(),
      ]);
      final target = ValidatedPublicTarget(
        Uri.parse('https://worldtime.example/api/timezone/Etc/UTC'),
        [
          InternetAddress('2606:4700:4700::1111'),
          InternetAddress('93.184.216.34'),
        ],
      );
      await PinnedPublicSourceTransport(
        connector: connector,
        clientFactory: _Factory(native),
      ).open(target);

      final task = await native.connectionFactory!(target.uri, null, null);
      expect(await task.socket, isA<_FakeSocket>());
      expect(connector.addresses.map((address) => address.type), [
        InternetAddressType.IPv6,
        InternetAddressType.IPv4,
      ]);
      expect(connector.hosts, ['worldtime.example', 'worldtime.example']);
    },
  );

  test('TLS failure tries next captured address without DNS', () async {
    final native = _NativeClient();
    final second = _FakeSocket();
    final connector = _SequenceConnector([
      const HandshakeException('test TLS failure'),
      second,
    ]);
    final target = ValidatedPublicTarget(Uri.parse('https://source.example/'), [
      InternetAddress('93.184.216.34'),
      InternetAddress('93.184.216.35'),
    ]);
    await PinnedPublicSourceTransport(
      connector: connector,
      clientFactory: _Factory(native),
    ).open(target);

    final task = await native.connectionFactory!(target.uri, null, null);
    expect(await task.socket, same(second));
    expect(connector.addresses, target.addresses);
    expect(connector.hosts, ['source.example', 'source.example']);
  });

  test('all captured failures produce stable network_failed', () async {
    final native = _NativeClient();
    final target = ValidatedPublicTarget(Uri.parse('https://source.example/'), [
      InternetAddress('93.184.216.34'),
      InternetAddress('93.184.216.35'),
    ]);
    await PinnedPublicSourceTransport(
      connector: _SequenceConnector([
        StateError('first failed'),
        StateError('second failed'),
      ]),
      clientFactory: _Factory(native),
    ).open(target);

    final task = await native.connectionFactory!(target.uri, null, null);
    await expectLater(
      task.socket,
      throwsA(
        isA<PublicSourceFailure>().having(
          (error) => error.code,
          'code',
          'network_failed',
        ),
      ),
    );
  });

  test(
    'cancellation during TCP aborts task and does not try next address',
    () async {
      final cancellation = _Cancellation();
      final connector = _PendingConnector();
      final native = _ConnectingNativeClient();
      final target = ValidatedPublicTarget(
        Uri.parse('https://source.example/'),
        [InternetAddress('93.184.216.34'), InternetAddress('93.184.216.35')],
      );
      final future = PinnedPublicSourceTransport(
        connector: connector,
        clientFactory: _Factory(native),
      ).open(target, cancellation: cancellation);
      await connector.started.future;

      cancellation.cancel();

      await expectLater(future, throwsA(_failure('cancelled')));
      expect(connector.cancelled, isTrue);
      expect(connector.addresses, [target.addresses.first]);
      expect(native.requestOpened, isFalse);
    },
  );

  test(
    'cancellation owns a task returned after connect future loses race',
    () async {
      final cancellation = _Cancellation();
      final lateSocket = _FakeSocket();
      final connector = _DelayedTaskConnector();
      final native = _ConnectingNativeClient();
      final target = ValidatedPublicTarget(
        Uri.parse('https://source.example/'),
        [InternetAddress('93.184.216.34'), InternetAddress('93.184.216.35')],
      );
      final future = PinnedPublicSourceTransport(
        connector: connector,
        clientFactory: _Factory(native),
      ).open(target, cancellation: cancellation);
      await connector.started.future;

      cancellation.cancel();
      await expectLater(future, throwsA(_failure('cancelled')));
      connector.completeWithSocket(lateSocket);
      await Future<void>.delayed(Duration.zero);

      expect(connector.cancelCount, 1);
      expect(connector.socketListened, isTrue);
      expect(lateSocket.destroyed, isTrue);
      expect(connector.addresses, [target.addresses.first]);
      expect(native.requestOpened, isFalse);
    },
  );

  test(
    'deadline owns a task returned after connect future loses race',
    () async {
      final lateSocket = _FakeSocket();
      final connector = _DelayedTaskConnector();
      final native = _ConnectingNativeClient();
      final target = ValidatedPublicTarget(
        Uri.parse('https://source.example/'),
        [InternetAddress('93.184.216.34'), InternetAddress('93.184.216.35')],
      );
      final future = PinnedPublicSourceTransport(
        connector: connector,
        clientFactory: _Factory(native),
        connectTimeout: const Duration(milliseconds: 20),
      ).open(target);
      await connector.started.future;

      await expectLater(future, throwsA(_failure('timeout')));
      connector.completeWithSocket(lateSocket);
      await Future<void>.delayed(Duration.zero);

      expect(connector.cancelCount, 1);
      expect(connector.socketListened, isTrue);
      expect(lateSocket.destroyed, isTrue);
      expect(connector.addresses, [target.addresses.first]);
      expect(native.requestOpened, isFalse);
    },
  );

  test('late connect error after cancellation is handled', () async {
    final cancellation = _Cancellation();
    final connector = _DelayedTaskConnector();
    final native = _ConnectingNativeClient();
    final target = ValidatedPublicTarget(Uri.parse('https://source.example/'), [
      InternetAddress('93.184.216.34'),
      InternetAddress('93.184.216.35'),
    ]);
    final future = PinnedPublicSourceTransport(
      connector: connector,
      clientFactory: _Factory(native),
    ).open(target, cancellation: cancellation);
    await connector.started.future;

    cancellation.cancel();
    await expectLater(future, throwsA(_failure('cancelled')));
    connector.completeError(StateError('late connect failure'));
    await Future<void>.delayed(Duration.zero);

    expect(connector.addresses, [target.addresses.first]);
    expect(native.requestOpened, isFalse);
  });

  test('normal delayed connect completion remains usable', () async {
    final socket = _FakeSocket();
    final connector = _DelayedTaskConnector();
    final native = _ConnectingNativeClient();
    final target = ValidatedPublicTarget(Uri.parse('https://source.example/'), [
      InternetAddress('93.184.216.34'),
    ]);
    final future = PinnedPublicSourceTransport(
      connector: connector,
      clientFactory: _Factory(native),
    ).open(target);
    await connector.started.future;

    connector.completeWithSocket(socket);
    await future;

    expect(connector.cancelCount, 0);
    expect(connector.socketListened, isTrue);
    expect(socket.destroyed, isFalse);
    expect(native.requestOpened, isTrue);
  });

  test(
    'cancellation during TLS closes raw socket and emits no request',
    () async {
      final cancellation = _Cancellation();
      final native = _ConnectingNativeClient();
      final connector = _PendingHandshakeConnector(events: native.events);
      final target = ValidatedPublicTarget(
        Uri.parse('https://source.example/'),
        [InternetAddress('93.184.216.34'), InternetAddress('93.184.216.35')],
      );
      final future = PinnedPublicSourceTransport(
        connector: connector,
        clientFactory: _Factory(native),
      ).open(target, cancellation: cancellation);
      await connector.started.future;

      cancellation.cancel();

      await expectLater(future, throwsA(_failure('cancelled')));
      expect(connector.abortCount, 1);
      expect(connector.addresses, [target.addresses.first]);
      expect(native.requestOpened, isFalse);
      expect(native.events, ['native_open', 'tls_started']);
    },
  );

  test(
    'one total deadline bounds fallback instead of resetting per candidate',
    () async {
      final native = _ConnectingNativeClient();
      final connector = _DelayedFallbackConnector();
      final target = ValidatedPublicTarget(
        Uri.parse('https://source.example/'),
        [InternetAddress('93.184.216.34'), InternetAddress('93.184.216.35')],
      );
      final stopwatch = Stopwatch()..start();

      await expectLater(
        PinnedPublicSourceTransport(
          connector: connector,
          clientFactory: _Factory(native),
          connectTimeout: const Duration(milliseconds: 80),
        ).open(target),
        throwsA(_failure('timeout')),
      );
      stopwatch.stop();

      expect(connector.addresses, target.addresses);
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 140)));
      expect(native.requestOpened, isFalse);
    },
  );

  test(
    'deadline aborts active TLS owner without trying next address',
    () async {
      final native = _ConnectingNativeClient();
      final connector = _PendingHandshakeConnector();
      final target = ValidatedPublicTarget(
        Uri.parse('https://source.example/'),
        [InternetAddress('93.184.216.34'), InternetAddress('93.184.216.35')],
      );

      await expectLater(
        PinnedPublicSourceTransport(
          connector: connector,
          clientFactory: _Factory(native),
          connectTimeout: const Duration(milliseconds: 20),
        ).open(target),
        throwsA(_failure('timeout')),
      );

      expect(connector.abortCount, 1);
      expect(connector.addresses, [target.addresses.first]);
      expect(native.requestOpened, isFalse);
    },
  );

  test(
    'native request becomes available only after TLS task completes',
    () async {
      final secure = _FakeSocket();
      final native = _ConnectingNativeClient();
      final connector = _CompletableHandshakeConnector(
        secure,
        events: native.events,
      );
      final target = ValidatedPublicTarget(
        Uri.parse('https://source.example/'),
        [InternetAddress('93.184.216.34')],
      );
      final future = PinnedPublicSourceTransport(
        connector: connector,
        clientFactory: _Factory(native),
      ).open(target);
      await connector.started.future;

      expect(native.requestOpened, isFalse);
      expect(native.events, ['native_open', 'tls_started']);
      connector.complete();
      await future;

      expect(native.requestOpened, isTrue);
      expect(native.events.last, 'request_open');
    },
  );

  test(
    'late TLS completion after repeated cancellation is destroyed once',
    () async {
      final cancellation = _Cancellation();
      final lateSecure = _FakeSocket();
      final connector = _CompletableHandshakeConnector(lateSecure);
      final native = _ConnectingNativeClient();
      final target = ValidatedPublicTarget(
        Uri.parse('https://source.example/'),
        [InternetAddress('93.184.216.34'), InternetAddress('93.184.216.35')],
      );
      final future = PinnedPublicSourceTransport(
        connector: connector,
        clientFactory: _Factory(native),
      ).open(target, cancellation: cancellation);
      await connector.started.future;

      cancellation.cancel();
      native.connectionTask?.cancel();
      native.connectionTask?.cancel();
      await expectLater(future, throwsA(_failure('cancelled')));
      connector.complete();
      await Future<void>.delayed(Duration.zero);

      expect(connector.abortCount, 1);
      expect(lateSecure.destroyed, isTrue);
      expect(connector.addresses, [target.addresses.first]);
    },
  );
}

Matcher _failure(String code) =>
    isA<PublicSourceFailure>().having((error) => error.code, 'code', code);

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

class _ConnectingNativeClient implements NativePublicSourceClient {
  PublicSourceConnectionFactory? connectionFactory;
  ConnectionTask<Socket>? connectionTask;
  final request = _Request();
  final events = <String>[];
  bool requestOpened = false;

  @override
  void configure({
    required bool autoUncompress,
    required Duration connectionTimeout,
    required String Function(Uri uri) findProxy,
    required PublicSourceConnectionFactory connectionFactory,
  }) => this.connectionFactory = connectionFactory;

  @override
  Future<NativePublicSourceRequest> open(Uri uri) async {
    events.add('native_open');
    connectionTask = await connectionFactory!(uri, null, null);
    await connectionTask!.socket;
    requestOpened = true;
    events.add('request_open');
    return request;
  }

  @override
  void close({required bool force}) => connectionTask?.cancel();
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
    int port, {
    required String host,
  }) async {
    this.address = address;
    this.port = port;
    calls++;
    throw const PublicSourceFailure('test_stop');
  }
}

class _SequenceConnector implements PublicSourceConnector {
  _SequenceConnector(this.results);
  final List<Object> results;
  final addresses = <InternetAddress>[];
  final hosts = <String>[];

  @override
  Future<ConnectionTask<Socket>> connect(
    InternetAddress address,
    int port, {
    required String host,
  }) async {
    addresses.add(address);
    hosts.add(host);
    final result = results[addresses.length - 1];
    if (result is Error || result is Exception) throw result;
    return ConnectionTask.fromSocket(Future.value(result as Socket), () {});
  }
}

class _PendingConnector implements PublicSourceConnector {
  final started = Completer<void>();
  final addresses = <InternetAddress>[];
  bool cancelled = false;

  @override
  Future<ConnectionTask<Socket>> connect(
    InternetAddress address,
    int port, {
    required String host,
  }) async {
    addresses.add(address);
    final socket = Completer<Socket>();
    final task = ConnectionTask.fromSocket(socket.future, () {
      cancelled = true;
    });
    if (!started.isCompleted) started.complete();
    return task;
  }
}

class _DelayedTaskConnector implements PublicSourceConnector {
  final started = Completer<void>();
  final _task = Completer<ConnectionTask<Socket>>();
  final addresses = <InternetAddress>[];
  int cancelCount = 0;
  bool socketListened = false;

  @override
  Future<ConnectionTask<Socket>> connect(
    InternetAddress address,
    int port, {
    required String host,
  }) {
    addresses.add(address);
    if (!started.isCompleted) started.complete();
    return _task.future;
  }

  void completeWithSocket(Socket socket) {
    final socketFuture = Future<Socket>.value(socket).then((value) {
      socketListened = true;
      return value;
    });
    _task.complete(
      ConnectionTask.fromSocket(socketFuture, () {
        cancelCount++;
      }),
    );
  }

  void completeError(Object error) => _task.completeError(error);
}

class _DelayedFallbackConnector implements PublicSourceConnector {
  final addresses = <InternetAddress>[];

  @override
  Future<ConnectionTask<Socket>> connect(
    InternetAddress address,
    int port, {
    required String host,
  }) async {
    addresses.add(address);
    if (addresses.length == 1) {
      await Future<void>.delayed(const Duration(milliseconds: 55));
      throw StateError('first failed');
    }
    return ConnectionTask.fromSocket(Completer<Socket>().future, () {});
  }
}

class _PendingHandshakeConnector implements PublicSourceConnector {
  _PendingHandshakeConnector({this.events});
  final List<String>? events;
  final started = Completer<void>();
  final addresses = <InternetAddress>[];
  int abortCount = 0;

  @override
  Future<ConnectionTask<Socket>> connect(
    InternetAddress address,
    int port, {
    required String host,
  }) async {
    addresses.add(address);
    events?.add('tls_started');
    started.complete();
    return ConnectionTask.fromSocket(Completer<Socket>().future, () {
      abortCount++;
    });
  }
}

class _CompletableHandshakeConnector implements PublicSourceConnector {
  _CompletableHandshakeConnector(this.secureSocket, {this.events});
  final Socket secureSocket;
  final List<String>? events;
  final started = Completer<void>();
  final result = Completer<Socket>();
  final addresses = <InternetAddress>[];
  var aborted = false;
  int abortCount = 0;

  @override
  Future<ConnectionTask<Socket>> connect(
    InternetAddress address,
    int port, {
    required String host,
  }) async {
    addresses.add(address);
    events?.add('tls_started');
    started.complete();
    final guarded = result.future.then<Socket>((socket) {
      if (aborted) {
        socket.destroy();
        throw const PublicSourceFailure('cancelled');
      }
      return socket;
    });
    return ConnectionTask.fromSocket(guarded, () {
      if (aborted) return;
      aborted = true;
      abortCount++;
    });
  }

  void complete() => result.complete(secureSocket);
}

class _FakeSocket implements Socket {
  bool destroyed = false;

  @override
  void destroy() => destroyed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Cancellation implements ChatToolCancellation {
  final _value = Completer<void>();
  @override
  bool get isCancelled => _value.isCompleted;
  @override
  Future<void> get whenCancelled => _value.future;
  void cancel() => _value.complete();
}
