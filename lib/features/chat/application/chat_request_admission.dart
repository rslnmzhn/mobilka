class ChatRequestAdmission {
  bool _held = false;

  bool tryAcquire() {
    if (_held) return false;
    _held = true;
    return true;
  }

  void release() => _held = false;
}
