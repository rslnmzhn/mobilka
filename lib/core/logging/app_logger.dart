import 'dart:convert';
import 'dart:developer' as developer;

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppLogLevel { debug, info, warning, error }

class AppLogEntry {
  const AppLogEntry({
    required this.timestamp,
    required this.event,
    required this.level,
    this.operationId,
    this.conversationId,
    this.toolCallId,
    this.status,
    this.errorType,
    this.duration,
    this.eventCount,
    this.terminalSeen,
    this.receivedAnyToken,
  });

  final DateTime timestamp;
  final String event;
  final AppLogLevel level;
  final String? operationId;
  final String? conversationId;
  final String? toolCallId;
  final String? status;
  final String? errorType;
  final Duration? duration;
  final int? eventCount;
  final bool? terminalSeen;
  final bool? receivedAnyToken;

  Map<String, Object> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'event': event,
    'level': level.name,
    // Pinned build_runner cannot parse null-aware elements yet.
    // ignore: use_null_aware_elements
    if (operationId != null) 'operationId': operationId!,
    // ignore: use_null_aware_elements
    if (conversationId != null) 'conversationId': conversationId!,
    // ignore: use_null_aware_elements
    if (toolCallId != null) 'toolCallId': toolCallId!,
    // ignore: use_null_aware_elements
    if (status != null) 'status': status!,
    // ignore: use_null_aware_elements
    if (errorType != null) 'errorType': errorType!,
    // ignore: use_null_aware_elements
    if (duration != null) 'durationMs': duration!.inMilliseconds,
    // ignore: use_null_aware_elements
    if (eventCount != null) 'eventCount': eventCount!,
    // ignore: use_null_aware_elements
    if (terminalSeen != null) 'terminalSeen': terminalSeen!,
    // ignore: use_null_aware_elements
    if (receivedAnyToken != null) 'receivedAnyToken': receivedAnyToken!,
  };

  @override
  String toString() => jsonEncode(toJson());
}

typedef AppLogSink = void Function(AppLogEntry entry);

class AppLogger {
  AppLogger({AppLogSink? sink, DateTime Function()? now})
    : _sink = sink ?? developerSink,
      _now = now ?? DateTime.now;

  final AppLogSink _sink;
  final DateTime Function() _now;

  static void developerSink(AppLogEntry entry) {
    developer.log(
      entry.toString(),
      name: 'mobilka',
      level: switch (entry.level) {
        AppLogLevel.debug => 500,
        AppLogLevel.info => 800,
        AppLogLevel.warning => 900,
        AppLogLevel.error => 1000,
      },
    );
  }

  void log({
    required String event,
    AppLogLevel level = AppLogLevel.info,
    String? operationId,
    String? conversationId,
    String? toolCallId,
    String? fileName,
    String? status,
    Object? error,
    Duration? duration,
    int? eventCount,
    bool? terminalSeen,
    bool? receivedAnyToken,
  }) {
    _sink(
      AppLogEntry(
        timestamp: _now(),
        event: _safeLabel(event),
        level: level,
        operationId: _safeIdentifier(operationId),
        conversationId: _safeIdentifier(conversationId),
        toolCallId: _safeIdentifier(toolCallId),
        status: status == null ? null : _safeLabel(status),
        errorType: error?.runtimeType.toString(),
        duration: duration,
        eventCount: eventCount,
        terminalSeen: terminalSeen,
        receivedAnyToken: receivedAnyToken,
      ),
    );
  }

  static final RegExp _safeLabelPattern = RegExp(r'^[a-z0-9_.-]{1,64}$');

  static String _safeLabel(String value) =>
      _safeLabelPattern.hasMatch(value) ? value : 'redacted';

  static String? _safeIdentifier(String? value) {
    if (value == null) return null;
    final digest = sha256.convert(utf8.encode(value)).toString();
    return 'sha256:${digest.substring(0, 16)}';
  }
}

class DiagnosticLogNotifier extends Notifier<List<AppLogEntry>> {
  static const capacity = 200;

  @override
  List<AppLogEntry> build() => const [];

  void add(AppLogEntry entry) {
    final start = state.length >= capacity ? state.length - capacity + 1 : 0;
    state = [...state.skip(start), entry];
  }

  void clear() => state = const [];
}

final diagnosticLogProvider =
    NotifierProvider<DiagnosticLogNotifier, List<AppLogEntry>>(
      DiagnosticLogNotifier.new,
    );

final appLoggerProvider = Provider<AppLogger>((ref) {
  return AppLogger(
    sink: (entry) {
      AppLogger.developerSink(entry);
      ref.read(diagnosticLogProvider.notifier).add(entry);
    },
  );
});
