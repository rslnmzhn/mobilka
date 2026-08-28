class RequestToolSecurityState {
  RequestToolSecurityState({
    required this.conversationId,
    required this.requestId,
  });

  final String conversationId;
  final String requestId;
  bool _sourceTainted = false;

  bool get sourceTainted => _sourceTainted;

  void markSourceTainted({
    required String conversationId,
    required String requestId,
  }) {
    if (conversationId != this.conversationId || requestId != this.requestId) {
      throw StateError('Request security identity changed');
    }
    _sourceTainted = true;
  }
}
