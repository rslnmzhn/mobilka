import 'dart:async';
import 'dart:convert';

import '../../chat/application/chat_tool_runtime.dart';
import '../../memory/application/prompt_guard.dart';
import '../../public_source/application/public_source_policy.dart';
import '../data/searxng_transport.dart';
import '../domain/searxng_search_settings.dart';
import 'web_search_policy.dart';

const webSearchResponseLimit = 256 * 1024;
const webSearchOutputLimit = 32 * 1024;

class WebSearchArguments {
  const WebSearchArguments(
    this.query,
    this.locale,
    this.timeRange,
    this.maxResults,
  );
  final String query;
  final String locale;
  final String timeRange;
  final int maxResults;
}

class SearxngSearchClient {
  const SearxngSearchClient({
    required this.policy,
    required this.transport,
    required this.guard,
    this.readTimeout = const Duration(seconds: 8),
  });
  final WebSearchPolicy policy;
  final SearxngTransport transport;
  final PromptGuard guard;
  final Duration readTimeout;

  Future<Map<String, Object?>> search(
    SearxngSearchSettings settings,
    WebSearchArguments arguments, {
    String? secret,
    required SearchExecutionDeadline execution,
    required Future<int> Function(int maximum) reserveWireBytes,
    required Future<void> Function(int unused) refundWireBytes,
  }) async {
    if (!settings.usable) throw const WebSearchFailure('search_disabled');
    if (settings.isHttp && secret?.isNotEmpty == true) {
      throw const WebSearchFailure('auth_requires_https');
    }
    final reserved = await execution.run(
      reserveWireBytes(webSearchResponseLimit),
    );
    var consumed = 0;
    SearxngResponse? activeResponse;
    try {
      final uri = WebSearchPolicy.searchUri(settings.baseUrl, {
        'q': arguments.query,
        'format': 'json',
        'language': arguments.locale,
        if (arguments.timeRange != 'none') 'time_range': arguments.timeRange,
        'pageno': '1',
      });
      final target = await execution.run(policy.validate(uri.toString()));
      final response = await execution.run(
        transport.get(
          target,
          headers: {
            'accept': 'application/json',
            'accept-encoding': 'identity',
            'user-agent': 'mobilka-web-search/1',
            if (secret?.isNotEmpty == true) 'authorization': 'Bearer $secret',
          },
          cancellation: execution,
        ),
      );
      activeResponse = response;
      try {
        if (_redirect(response.status)) {
          throw const WebSearchFailure('redirect_not_allowed');
        }
        if (response.status < 200 || response.status >= 300) {
          throw const WebSearchFailure('provider_error');
        }
        final type = response.headers['content-type']?.toLowerCase() ?? '';
        if (!RegExp(
          r'^application/json(?:\s*;\s*charset=utf-?8)?\s*$',
        ).hasMatch(type)) {
          throw const WebSearchFailure('invalid_response');
        }
        final encoding = response.headers['content-encoding'];
        if (encoding != null &&
            encoding.trim().isNotEmpty &&
            encoding.trim().toLowerCase() != 'identity') {
          throw const WebSearchFailure('invalid_response');
        }
        final length = int.tryParse(response.headers['content-length'] ?? '');
        if (length != null && length > webSearchResponseLimit) {
          throw const WebSearchFailure('response_too_large');
        }
        final body = <int>[];
        final iterator = StreamIterator(response.body);
        try {
          while (await execution.run(iterator.moveNext(), limit: readTimeout)) {
            body.addAll(iterator.current);
            consumed += iterator.current.length;
            if (consumed > reserved || body.length > webSearchResponseLimit) {
              throw const WebSearchFailure('response_too_large');
            }
          }
        } finally {
          await iterator.cancel();
        }
        return await _parse(body, arguments.maxResults, execution);
      } finally {
        await response.abort?.call();
        activeResponse = null;
      }
    } finally {
      execution.cancel();
      await activeResponse?.abort?.call();
      await refundWireBytes((reserved - consumed).clamp(0, reserved));
    }
  }

  Future<Map<String, Object?>> _parse(
    List<int> bytes,
    int maximum,
    SearchExecutionDeadline execution,
  ) async {
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on Object {
      throw const WebSearchFailure('invalid_response');
    }
    if (decoded is! Map || decoded['results'] is! List) {
      throw const WebSearchFailure('invalid_response');
    }
    final results = <Map<String, Object?>>[];
    final seen = <String>{};
    for (final candidate in (decoded['results'] as List).take(50)) {
      if (candidate is! Map) continue;
      final title = candidate['title'];
      final rawUrl = candidate['url'];
      final snippet = candidate['content'] ?? candidate['snippet'] ?? '';
      if (title is! String ||
          rawUrl is! String ||
          snippet is! String ||
          utf8.encode(title).length > 300 ||
          utf8.encode(snippet).length > 1000) {
        continue;
      }
      Uri canonical;
      try {
        final uri = Uri.parse(rawUrl);
        if (!const {'http', 'https'}.contains(uri.scheme) ||
            uri.userInfo.isNotEmpty ||
            uri.fragment.isNotEmpty ||
            uri.host.isEmpty) {
          continue;
        }
        canonical = PublicTargetPolicy.canonicalize(uri.replace(fragment: ''));
        final validated = await execution.run(
          policy.validate(canonical.toString()),
        );
        canonical = validated.uri;
      } on Object {
        continue;
      }
      if (!seen.add(canonical.toString())) continue;
      final guardedTitle = guard.sanitize(title);
      final guardedSnippet = guard.sanitize(snippet);
      final item = <String, Object?>{
        'title': guardedTitle.content,
        'url': canonical.toString(),
        'snippet': guardedSnippet.content,
        'guard': {
          'heuristic_only': true,
          'suspicious_line_count':
              guardedTitle.suspiciousLines.length +
              guardedSnippet.suspiciousLines.length,
        },
      };
      final proposed = jsonEncode({
        'untrusted': true,
        'provider': 'searxng',
        'results': [...results, item],
      });
      if (utf8.encode(proposed).length > webSearchOutputLimit) break;
      results.add(item);
      if (results.length == maximum) break;
    }
    return {'untrusted': true, 'provider': 'searxng', 'results': results};
  }

  bool _redirect(int status) =>
      const {301, 302, 303, 307, 308}.contains(status);
}

class SearchExecutionDeadline implements ChatToolCancellation {
  SearchExecutionDeadline(Duration timeout, ChatToolCancellation? parent)
    : deadline = DateTime.now().add(timeout) {
    _timer = Timer(timeout, () {
      timedOut = true;
      cancel();
    });
    parent?.whenCancelled.then((_) => cancel()).ignore();
  }
  late final Timer _timer;
  final DateTime deadline;
  final Completer<void> _done = Completer<void>();
  bool timedOut = false;
  @override
  bool get isCancelled => _done.isCompleted;
  @override
  Future<void> get whenCancelled => _done.future;
  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }

  Future<T> run<T>(Future<T> operation, {Duration? limit}) {
    if (isCancelled) {
      throw WebSearchFailure(timedOut ? 'timeout' : 'cancelled');
    }
    final remaining = deadline.difference(DateTime.now());
    final duration = limit != null && limit < remaining ? limit : remaining;
    if (duration <= Duration.zero) {
      timedOut = true;
      cancel();
      throw const WebSearchFailure('timeout');
    }
    return Future.any([
      operation.timeout(
        duration,
        onTimeout: () {
          timedOut = true;
          cancel();
          throw const WebSearchFailure('timeout');
        },
      ),
      whenCancelled.then<T>(
        (_) => throw WebSearchFailure(timedOut ? 'timeout' : 'cancelled'),
      ),
    ]);
  }

  void dispose() => _timer.cancel();
}
