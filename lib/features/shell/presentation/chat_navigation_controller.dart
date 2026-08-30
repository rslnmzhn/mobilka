import 'package:flutter/foundation.dart';

class ChatNavigationController extends ChangeNotifier {
  bool _visible = false;
  String _path = '';
  bool _isNarrow = false;

  bool get visible => _visible;
  bool get canShow => _path == '/chat' && _isNarrow;

  void show() {
    if (!canShow || _visible) return;
    _visible = true;
    notifyListeners();
  }

  void hide() {
    if (!_visible) return;
    _visible = false;
    notifyListeners();
  }

  void updatePath(String path, {bool notify = true}) {
    if (path == _path) return;
    _path = path;
    _resetVisibility(notify: notify);
  }

  void updateWidth(bool isNarrow, {bool notify = true}) {
    if (isNarrow == _isNarrow) return;
    _isNarrow = isNarrow;
    _resetVisibility(notify: notify);
  }

  void _resetVisibility({required bool notify}) {
    if (!_visible) return;
    _visible = false;
    if (notify) notifyListeners();
  }

  void onDestination(int destination, int currentDestination) {
    if (destination != currentDestination) hide();
  }
}
