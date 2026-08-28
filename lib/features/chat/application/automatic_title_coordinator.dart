import '../domain/conversation.dart';

class AutomaticTitleCoordinator {
  AutomaticTitleCoordinator({
    required Conversation? Function(String id) conversationById,
    required Future<void> Function(Conversation conversation) persist,
  }) : _conversationById = conversationById,
       _persist = persist;

  final Conversation? Function(String id) _conversationById;
  final Future<void> Function(Conversation conversation) _persist;
  final Map<String, Future<void>> _operations = {};

  Future<Conversation?> mutate(
    String conversationId,
    Conversation? Function(Conversation latest) mutation,
  ) => _serialize(conversationId, () async {
    final latest = _conversationById(conversationId);
    if (latest == null) return null;
    final updated = mutation(latest);
    if (updated == null) return null;
    await _persist(updated);
    return updated;
  });

  Future<T> serialize<T>(String conversationId, Future<T> Function() action) =>
      _serialize(conversationId, action);

  Future<Conversation?> claim(String conversationId) =>
      _serialize(conversationId, () async {
        final latest = _conversationById(conversationId);
        if (latest == null ||
            latest.titleState != ConversationTitleState.pendingAutomatic) {
          return null;
        }
        final claimed = latest.copyWith(
          titleState: ConversationTitleState.fallback,
        );
        await _persist(claimed);
        return claimed;
      });

  Future<void> complete(String conversationId, String title) =>
      _serialize(conversationId, () async {
        final latest = _conversationById(conversationId);
        if (latest == null ||
            latest.titleState != ConversationTitleState.fallback) {
          return;
        }
        await _persist(
          latest.copyWith(
            title: title,
            titleState: ConversationTitleState.generated,
          ),
        );
      });

  Future<T> _serialize<T>(String id, Future<T> Function() operation) {
    final previous = _operations[id] ?? Future.value();
    final result = previous.then((_) => operation());
    final marker = result.then<void>((_) {}, onError: (_) {});
    _operations[id] = marker;
    marker.whenComplete(() {
      if (identical(_operations[id], marker)) _operations.remove(id);
    });
    return result;
  }
}
