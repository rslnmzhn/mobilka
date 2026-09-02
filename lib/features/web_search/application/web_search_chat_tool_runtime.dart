import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../chat/application/chat_tool_runtime.dart';
import '../../chat/domain/chat_message.dart';
import '../../chat/domain/chat_tool.dart';
import '../../memory/application/prompt_guard.dart';
import '../../public_source/application/public_source_policy.dart';
import '../data/searxng_transport.dart';
import '../domain/searxng_search_settings.dart';
import 'searxng_search_client.dart';
import 'searxng_settings_controller.dart';
import 'searxng_settings_repository.dart';
import 'web_search_policy.dart';

final webSearchChatToolRuntimeProvider = Provider<WebSearchChatToolRuntime>((
  ref,
) {
  return WebSearchChatToolRuntime(
    loadSettings: () async =>
        ref.read(searxngSettingsControllerProvider.future),
    loadSecret: (endpoint) =>
        ref.read(searxngSettingsRepositoryProvider).getSecretFor(endpoint),
    createClient: () => SearxngSearchClient(
      policy: WebSearchPolicy(
        PublicTargetPolicy(
          const SystemPublicSourceResolver(),
          allowedSchemes: const {'http', 'https'},
        ),
      ),
      transport: const DirectSearxngTransport(),
      guard: ref.watch(promptGuardProvider),
    ),
    logger: ref.watch(appLoggerProvider),
  );
});

class WebSearchChatToolRuntime implements ChatToolRuntime {
  WebSearchChatToolRuntime({
    required this.loadSettings,
    required this.loadSecret,
    SearxngSearchClient? client,
    SearxngSearchClient Function()? createClient,
    this.totalTimeout = const Duration(seconds: 15),
    AppLogger? logger,
  }) : assert(client != null || createClient != null),
       _client = client,
       _createClient = createClient,
       logger = logger ?? AppLogger();
  final Future<SearxngSearchSettings> Function() loadSettings;
  final Future<String?> Function(String endpoint) loadSecret;
  final SearxngSearchClient? _client;
  final SearxngSearchClient Function()? _createClient;
  final AppLogger logger;
  final Duration totalTimeout;
  SearxngSearchClient get client => _client ?? _createClient!();

  static const definition = ChatToolDefinition(
    effect: ChatToolEffect.readOnly,
    name: 'web_search',
    description:
        'Discover untrusted public web result titles, URLs, and snippets through the configured SearXNG server. Search results are not source evidence: explicitly choose an HTTPS result and call read_public_source before citations or content claims.',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
        'locale': {'type': 'string'},
        'time_range': {
          'type': 'string',
          'enum': ['none', 'day', 'week', 'month', 'year'],
        },
        'max_results': {'type': 'integer', 'minimum': 1, 'maximum': 10},
      },
      'required': ['query'],
      'additionalProperties': false,
    },
  );

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async {
    if (!allowedTools.contains(definition.name)) return const [];
    final settings = await loadSettings();
    return settings.usable ? const [definition] : const [];
  }

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) async {
    final started = DateTime.now();
    SearchExecutionDeadline? execution;
    try {
      if (call.name != definition.name ||
          !allowedTools.contains(definition.name)) {
        throw const WebSearchFailure('not_allowed');
      }
      if (context?.conversationId.isEmpty != false ||
          context?.reservePublicSourceWireBytes == null ||
          context?.refundPublicSourceWireBytes == null) {
        throw const WebSearchFailure('missing_context');
      }
      execution = SearchExecutionDeadline(totalTimeout, context!.cancellation);
      final settings = await execution.run(loadSettings());
      if (!settings.usable) throw const WebSearchFailure('search_disabled');
      final args = _arguments(call.arguments, settings);
      final result = await client.search(
        settings,
        args,
        secret: settings.hasSecret
            ? await execution.run(loadSecret(settings.baseUrl))
            : null,
        execution: execution,
        reserveWireBytes: context.reservePublicSourceWireBytes!,
        refundWireBytes: context.refundPublicSourceWireBytes!,
      );
      logger.log(
        event: 'web_search.runtime',
        status: 'ok',
        duration: DateTime.now().difference(started),
        eventCount: (result['results'] as List).length,
      );
      return jsonEncode({'ok': true, ...result});
    } on WebSearchFailure catch (error) {
      logger.log(
        event: 'web_search.runtime',
        status: error.code,
        duration: DateTime.now().difference(started),
      );
      return jsonEncode({'ok': false, 'error_code': error.code});
    } on Object catch (error) {
      logger.log(
        event: 'web_search.runtime',
        level: AppLogLevel.error,
        status: 'internal_error',
        duration: DateTime.now().difference(started),
        error: error,
      );
      return jsonEncode({'ok': false, 'error_code': 'internal_error'});
    } finally {
      execution?.dispose();
    }
  }

  WebSearchArguments _arguments(String raw, SearxngSearchSettings defaults) {
    if (_hasDuplicateTopLevelKeys(raw)) {
      throw const WebSearchFailure('invalid_arguments');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on Object {
      throw const WebSearchFailure('invalid_arguments');
    }
    if (decoded is! Map ||
        decoded.keys.any(
          (key) => !const {
            'query',
            'locale',
            'time_range',
            'max_results',
          }.contains(key),
        )) {
      throw const WebSearchFailure('invalid_arguments');
    }
    final query = decoded['query'];
    final locale = decoded['locale'] ?? defaults.locale;
    final range = decoded['time_range'] ?? defaults.timeRange;
    final maximum = decoded['max_results'] ?? defaults.maxResults;
    if (query is! String ||
        query.isEmpty ||
        utf8.encode(query).length > 512 ||
        query.runes.any((r) => r < 32 || r == 127) ||
        maximum is! int ||
        maximum < 1 ||
        maximum > 10) {
      throw const WebSearchFailure('invalid_arguments');
    }
    try {
      return WebSearchArguments(
        query,
        validateSearchLocale(locale),
        validateSearchTimeRange(range),
        maximum,
      );
    } on WebSearchFailure {
      throw const WebSearchFailure('invalid_arguments');
    }
  }

  bool _hasDuplicateTopLevelKeys(String raw) {
    var depth = 0;
    var escaped = false;
    var inString = false;
    var start = 0;
    final keys = <String>{};
    for (var i = 0; i < raw.length; i++) {
      final character = raw[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (character == r'\') {
          escaped = true;
        } else if (character == '"') {
          inString = false;
          var next = i + 1;
          while (next < raw.length && raw.codeUnitAt(next) <= 32) {
            next++;
          }
          if (depth == 1 && next < raw.length && raw[next] == ':') {
            final key = raw.substring(start, i);
            if (!keys.add(key)) return true;
          }
        }
      } else if (character == '"') {
        inString = true;
        start = i + 1;
      } else if (character == '{' || character == '[') {
        depth++;
      } else if (character == '}' || character == ']') {
        depth--;
      }
    }
    return false;
  }
}
