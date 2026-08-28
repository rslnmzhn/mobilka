import 'dart:async';
import 'dart:convert';

import '../../chat/application/chat_tool_runtime.dart';
import '../../memory/application/prompt_guard.dart';
import '../data/public_source_transport.dart';
import 'public_source_policy.dart';
import 'public_source_cache.dart';

const publicSourceChunkLimit = 256 * 1024;
const publicSourceConversationWireLimit = 8 * 1024 * 1024;
const _untrustedStart = '<untrusted_public_source>\n';
const _untrustedEnd = '\n</untrusted_public_source>';

class PublicSourceReader {
  PublicSourceReader({
    required this.policy,
    required this.transport,
    required this.guard,
    this.readTimeout = const Duration(seconds: 8),
    this.totalTimeout = const Duration(seconds: 20),
  });
  final PublicSourcePolicy policy;
  final PublicSourceTransport transport;
  final PromptGuard guard;
  final Duration readTimeout;
  final Duration totalTimeout;
  final Map<String, PublicSourceScopedCache> _scopes = {};

  Future<Map<String, Object?>> read(
    String requestedUrl,
    int offset, {
    required String scope,
    ChatToolCancellation? cancellation,
    Future<void> Function(int bytes)? consumeWireBytes,
    Future<int> Function(int maximum)? reserveWireBytes,
    Future<void> Function(int unused)? refundWireBytes,
  }) async {
    if (offset < 0 || offset > publicSourceTransferLimit) {
      throw const PublicSourceFailure('invalid_offset');
    }
    final deadline = DateTime.now().add(totalTimeout);
    final operationCancellation = _DeadlineCancellation(
      totalTimeout,
      cancellation,
    );
    try {
      final initial = await _within(
        policy.validate(requestedUrl),
        deadline,
        operationCancellation,
      );
      final cache = _scopes.putIfAbsent(scope, PublicSourceScopedCache.new);
      final cached = cache.lookup(initial.uri.toString());
      if (cached != null) return _chunk(requestedUrl, offset, cached, 0);
      final reserved = reserveWireBytes == null
          ? publicSourceTransferLimit
          : await reserveWireBytes(publicSourceTransferLimit);
      var consumed = 0;
      try {
        return await _fetch(
          requestedUrl,
          offset,
          initial,
          cache,
          deadline,
          operationCancellation,
          reserveWireBytes == null
              ? consumeWireBytes
              : (bytes) async {
                  consumed += bytes;
                  if (consumed > reserved) {
                    throw const PublicSourceFailure('response_too_large');
                  }
                },
        );
      } finally {
        if (reserveWireBytes != null) {
          await refundWireBytes?.call((reserved - consumed).clamp(0, reserved));
        }
      }
    } finally {
      operationCancellation.dispose();
    }
  }

  void removeScope(String scope) => _scopes.remove(scope);

  Future<Map<String, Object?>> _fetch(
    String requestedUrl,
    int offset,
    ValidatedPublicTarget initial,
    PublicSourceScopedCache cache,
    DateTime deadline,
    ChatToolCancellation? cancellation,
    Future<void> Function(int bytes)? consumeWireBytes,
  ) async {
    var target = initial;
    final aliases = <String>[target.uri.toString()];
    final seen = aliases.toSet();
    var redirects = 0;
    var transferred = 0;
    while (true) {
      final response = await _within(
        transport.open(target, cancellation: cancellation),
        deadline,
        cancellation,
      );
      try {
        if (_isRedirect(response.status)) {
          final redirect = await _followRedirect(
            response,
            target,
            seen,
            aliases,
            redirects,
            cache,
            deadline,
            cancellation,
          );
          if (redirect.cached != null) {
            return _chunk(
              requestedUrl,
              offset,
              redirect.cached!,
              redirects + 1,
            );
          }
          target = redirect.target;
          redirects++;
          continue;
        }
        _validateHeaders(response);
        final body = await _readBody(
          response,
          transferred,
          deadline,
          cancellation,
          consumeWireBytes,
        );
        transferred += body.length;
        final source = _validateText(target, response.headers, body);
        cache.store(source, aliases);
        return _chunk(requestedUrl, offset, source, redirects);
      } finally {
        response.abort();
      }
    }
  }

  Future<({ValidatedPublicTarget target, PublicSourceCacheEntry? cached})>
  _followRedirect(
    PublicSourceResponse response,
    ValidatedPublicTarget current,
    Set<String> seen,
    List<String> aliases,
    int redirects,
    PublicSourceScopedCache cache,
    DateTime deadline,
    ChatToolCancellation? cancellation,
  ) async {
    if (redirects == 5) {
      throw const PublicSourceFailure('too_many_redirects');
    }
    final location = response.headers['location'];
    if (location == null) throw const PublicSourceFailure('invalid_redirect');
    response.abort();
    final target = await _within(
      policy.validate(current.uri.resolve(location).toString()),
      deadline,
      cancellation,
    );
    final identity = target.uri.toString();
    if (!seen.add(identity)) throw const PublicSourceFailure('redirect_loop');
    aliases.add(identity);
    final cached = cache.lookup(identity);
    if (cached != null) cache.aliasAll(aliases, cached);
    return (target: target, cached: cached);
  }

  void _validateHeaders(PublicSourceResponse response) {
    if (response.status < 200 || response.status >= 300) {
      throw const PublicSourceFailure('http_error');
    }
    if (response.contentLength > publicSourceTransferLimit) {
      throw const PublicSourceFailure('response_too_large');
    }
    final encoding = response.headers['content-encoding']?.trim().toLowerCase();
    if (encoding != null && encoding.isNotEmpty && encoding != 'identity') {
      throw const PublicSourceFailure('unsupported_encoding');
    }
  }

  Future<List<int>> _readBody(
    PublicSourceResponse response,
    int alreadyTransferred,
    DateTime deadline,
    ChatToolCancellation? cancellation,
    Future<void> Function(int bytes)? consumeWireBytes,
  ) async {
    final bytes = <int>[];
    final iterator = StreamIterator(response.body);
    try {
      while (await _within(
        iterator.moveNext(),
        deadline,
        cancellation,
        limit: readTimeout,
      )) {
        bytes.addAll(iterator.current);
        await consumeWireBytes?.call(iterator.current.length);
        if (alreadyTransferred + bytes.length > publicSourceTransferLimit) {
          throw const PublicSourceFailure('response_too_large');
        }
      }
      return bytes;
    } finally {
      await iterator.cancel();
    }
  }

  PublicSourceCacheEntry _validateText(
    ValidatedPublicTarget target,
    Map<String, String> headers,
    List<int> body,
  ) {
    final media = _media(headers['content-type']);
    if (!_allowedMime(media.mime)) {
      throw const PublicSourceFailure('unsupported_mime');
    }
    if (body.contains(0)) throw const PublicSourceFailure('invalid_text');
    final decoder = _decoder(media.charset);
    _decode(decoder, body);
    return PublicSourceCacheEntry(
      finalUrl: target.uri.toString(),
      mime: media.mime,
      charset: media.charset,
      body: List.unmodifiable(body),
    );
  }

  Map<String, Object?> _chunk(
    String requestedUrl,
    int offset,
    PublicSourceCacheEntry source,
    int redirects,
  ) {
    final body = source.body;
    if (body.isEmpty && offset == 0) {
      return _result(requestedUrl, source, 0, 0, redirects, '');
    }
    if (offset >= body.length) throw const PublicSourceFailure('offset_at_end');
    final decoder = _decoder(source.charset);
    if (offset > 0) _decode(decoder, body.sublist(0, offset));
    var low = offset;
    var high = (offset + publicSourceChunkLimit).clamp(offset, body.length);
    var bestEnd = offset;
    var best = '';
    while (low <= high) {
      final candidate = _previousBoundary(
        decoder,
        body,
        offset,
        (low + high) ~/ 2,
      );
      final guarded = guard.sanitize(
        _decode(decoder, body.sublist(offset, candidate)),
      );
      final wrapped = '$_untrustedStart${guarded.content}$_untrustedEnd';
      if (utf8.encode(wrapped).length <= publicSourceChunkLimit) {
        bestEnd = candidate;
        best = wrapped;
        low = candidate + 1;
      } else {
        high = candidate - 1;
      }
    }
    if (bestEnd == offset) {
      throw const PublicSourceFailure('chunk_unrepresentable');
    }
    return _result(requestedUrl, source, offset, bestEnd, redirects, best);
  }

  Map<String, Object?> _result(
    String requestedUrl,
    PublicSourceCacheEntry source,
    int offset,
    int end,
    int redirects,
    String content,
  ) {
    final guarded = guard.sanitize(
      source.body.isEmpty
          ? ''
          : _decode(_decoder(source.charset), source.body.sublist(offset, end)),
    );
    final hasMore = end < source.body.length;
    return {
      'ok': true,
      'trust': 'untrusted_data_not_instructions',
      'requested_url': requestedUrl,
      'final_url': source.finalUrl,
      'mime': source.mime,
      'charset': source.charset,
      'redirects': redirects,
      'offset': offset,
      'bytes_returned': end - offset,
      'total_bytes_observed': source.body.length,
      'next_offset': hasMore ? end : null,
      'has_more': hasMore,
      'guard': {
        'heuristic_only': true,
        'frontmatter_stripped': guarded.frontmatterStripped,
        'suspicious_line_count': guarded.suspiciousLines.length,
      },
      'content': content,
    };
  }

  int _previousBoundary(Encoding decoder, List<int> body, int start, int end) {
    while (end > start) {
      try {
        _decode(decoder, body.sublist(start, end));
        return end;
      } on PublicSourceFailure {
        end--;
      }
    }
    return start;
  }

  Future<T> _within<T>(
    Future<T> operation,
    DateTime deadline,
    ChatToolCancellation? cancellation, {
    Duration? limit,
  }) {
    if (cancellation?.isCancelled == true) {
      throw const PublicSourceFailure('cancelled');
    }
    final remaining = deadline.difference(DateTime.now());
    final duration = limit != null && limit < remaining ? limit : remaining;
    if (duration <= Duration.zero) throw const PublicSourceFailure('timeout');
    final futures = <Future<T>>[
      operation.timeout(
        duration,
        onTimeout: () {
          throw const PublicSourceFailure('timeout');
        },
      ),
    ];
    if (cancellation != null) {
      futures.add(
        cancellation.whenCancelled.then<T>((_) {
          throw const PublicSourceFailure('cancelled');
        }),
      );
    }
    return Future.any(futures);
  }

  bool _isRedirect(int status) =>
      const {301, 302, 303, 307, 308}.contains(status);

  ({String mime, String charset}) _media(String? raw) {
    if (raw == null) throw const PublicSourceFailure('missing_mime');
    final parts = raw.toLowerCase().split(';');
    var charset = 'utf-8';
    for (final part in parts.skip(1)) {
      final value = part.trim();
      if (value.startsWith('charset=')) {
        charset = value.substring(8).replaceAll('"', '');
      }
    }
    return (mime: parts.first.trim(), charset: charset);
  }

  bool _allowedMime(String mime) =>
      mime.startsWith('text/') ||
      const {
        'application/json',
        'application/xml',
        'application/javascript',
        'application/x-javascript',
        'application/yaml',
        'application/x-yaml',
        'application/toml',
      }.contains(mime) ||
      mime.endsWith('+json') ||
      mime.endsWith('+xml');

  Encoding _decoder(String charset) => switch (charset) {
    'utf-8' || 'utf8' => utf8,
    'us-ascii' || 'ascii' => ascii,
    'iso-8859-1' || 'latin1' || 'latin-1' => latin1,
    _ => throw const PublicSourceFailure('unsupported_charset'),
  };

  String _decode(Encoding encoding, List<int> bytes) {
    try {
      if (encoding == utf8) return utf8.decode(bytes, allowMalformed: false);
      if (encoding == ascii) return ascii.decode(bytes, allowInvalid: false);
      return latin1.decode(bytes);
    } on FormatException {
      throw const PublicSourceFailure('invalid_text');
    }
  }
}

class _DeadlineCancellation implements ChatToolCancellation {
  _DeadlineCancellation(Duration duration, ChatToolCancellation? parent)
    : _parent = parent {
    _timer = Timer(duration, _cancel);
    parent?.whenCancelled.then((_) => _cancel()).ignore();
  }

  final ChatToolCancellation? _parent;
  late final Timer _timer;
  final Completer<void> _cancelled = Completer<void>();

  @override
  bool get isCancelled =>
      _cancelled.isCompleted || _parent?.isCancelled == true;

  @override
  Future<void> get whenCancelled => _cancelled.future;

  void _cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void dispose() => _timer.cancel();
}
