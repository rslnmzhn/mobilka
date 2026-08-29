import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../application/public_source_policy.dart';

abstract interface class PublicSourceConnector {
  Future<ConnectionTask<Socket>> connect(
    InternetAddress address,
    int port, {
    required String host,
  });
}

class DirectPublicSourceConnector implements PublicSourceConnector {
  const DirectPublicSourceConnector();

  @override
  Future<ConnectionTask<Socket>> connect(
    InternetAddress address,
    int port, {
    required String host,
  }) async {
    final task = await RawSocket.startConnect(address, port);
    RawSocket? raw;
    var aborted = false;
    final socket = task.socket
        .then((connected) {
          raw = connected;
          if (aborted) {
            connected.close();
            throw const PublicSourceFailure('cancelled');
          }
          return RawSecureSocket.secure(
            connected,
            host: host,
            context: SecurityContext.defaultContext,
          );
        })
        .then<Socket>((secure) {
          if (aborted) {
            secure.close();
            throw const PublicSourceFailure('cancelled');
          }
          return _RawSecureSocketAdapter(secure);
        });
    return ConnectionTask.fromSocket(socket, () {
      if (aborted) return;
      aborted = true;
      task.cancel();
      raw?.close();
    });
  }
}

class _RawSecureSocketAdapter extends Stream<Uint8List> implements Socket {
  _RawSecureSocketAdapter(this._raw) {
    _subscription = _raw.listen(
      _onEvent,
      onError: _data.addError,
      onDone: _onDone,
      cancelOnError: false,
    );
  }

  final RawSecureSocket _raw;
  final _data = StreamController<Uint8List>();
  final _closed = Completer<void>();
  late final StreamSubscription<RawSocketEvent> _subscription;
  Completer<void>? _writable;
  bool _destroyed = false;

  void _onEvent(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final bytes = _raw.read();
      if (bytes != null && bytes.isNotEmpty) _data.add(bytes);
    } else if (event == RawSocketEvent.write) {
      _writable?.complete();
      _writable = null;
    } else if (event == RawSocketEvent.readClosed) {
      _data.close();
    }
  }

  void _onDone() {
    _data.close();
    if (!_closed.isCompleted) _closed.complete();
  }

  Future<void> _writeBytes(List<int> data) async {
    var offset = 0;
    while (offset < data.length && !_destroyed) {
      final written = _raw.write(data, offset, data.length - offset);
      if (written > 0) {
        offset += written;
      } else {
        _writable ??= Completer<void>();
        await _writable!.future;
      }
    }
    if (_destroyed) throw const SocketException('Socket is closed');
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _data.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  void add(List<int> data) => _writeBytes(data).catchError((Object error) {
    _data.addError(error);
  });
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _data.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      await _writeBytes(data);
    }
  }

  @override
  Encoding encoding = utf8;
  @override
  void write(Object? object) =>
      add(encoding.encode(object?.toString() ?? 'null'));
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));
  @override
  void writeln([Object? object = '']) => write('$object\n');
  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));
  @override
  Future<void> flush() async {
    while (_writable != null) {
      await _writable!.future;
    }
  }

  @override
  Future<void> close() async {
    if (_destroyed) return;
    _destroyed = true;
    await _raw.close();
    await _subscription.cancel();
    await _data.close();
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> get done => _closed.future;
  @override
  void destroy() => close().ignore();
  @override
  InternetAddress get address => _raw.address;
  @override
  int get port => _raw.port;
  @override
  InternetAddress get remoteAddress => _raw.remoteAddress;
  @override
  int get remotePort => _raw.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _raw.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _raw.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _raw.setRawOption(option);
}
