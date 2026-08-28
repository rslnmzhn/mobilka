import '../../../core/logging/app_logger.dart';
import 'background_task_bridge.dart';
import 'chat_stream_request.dart';

class ChatBackgroundLease {
  const ChatBackgroundLease({
    required this.bridge,
    required this.publishUnavailable,
    this.logger,
  });

  final BackgroundTaskBridge bridge;
  final void Function() publishUnavailable;
  final AppLogger? logger;

  Future<void> acquire(ChatStreamRequest request) async {
    BackgroundTaskStartResult result;
    try {
      result = await bridge.start(
        ownerId: request.requestMessageId,
        title: AndroidForegroundTaskBridge.notificationTitle,
      );
    } on Object {
      result = BackgroundTaskStartResult.unavailable;
    }
    if (result == BackgroundTaskStartResult.unavailable) publishUnavailable();
    logger?.log(
      event: 'chat.background_service',
      conversationId: request.conversationId,
      status: result.name,
    );
  }

  Future<void> release(ChatStreamRequest request) async {
    try {
      final result = await bridge.stop(ownerId: request.requestMessageId);
      logger?.log(
        event: 'chat.background_service',
        level: result == BackgroundTaskStopResult.retainedForRetry
            ? AppLogLevel.warning
            : AppLogLevel.info,
        conversationId: request.conversationId,
        status: switch (result) {
          BackgroundTaskStopResult.released => 'released',
          BackgroundTaskStopResult.notRunning => 'not_running',
          BackgroundTaskStopResult.retainedForRetry => 'retained_for_retry',
        },
      );
    } on Object catch (error) {
      logger?.log(
        event: 'chat.background_service',
        level: AppLogLevel.warning,
        conversationId: request.conversationId,
        status: 'stop_failed',
        error: error,
      );
    }
  }
}
