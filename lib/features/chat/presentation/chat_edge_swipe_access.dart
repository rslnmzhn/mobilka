import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

enum ChatEdgeSwipeAction { history, artifacts }

@visibleForTesting
class ChatEdgeSwipeAccess extends StatefulWidget {
  const ChatEdgeSwipeAccess({
    required this.child,
    required this.canPresent,
    required this.onHistory,
    required this.onArtifacts,
    super.key,
  });

  final Widget child;
  final bool Function() canPresent;
  final VoidCallback onHistory;
  final VoidCallback onArtifacts;

  @override
  State<ChatEdgeSwipeAccess> createState() => _ChatEdgeSwipeAccessState();
}

class _ChatEdgeSwipeAccessState extends State<ChatEdgeSwipeAccess> {
  static const _bandWidth = 28.0;
  static const _threshold = 72.0;
  static const _dominance = 1.8;
  static const _touchSlop = 18.0;

  Offset? _start;
  ChatEdgeSwipeAction? _candidate;
  var _triggered = false;

  @override
  Widget build(BuildContext context) => Listener(
    key: const Key('chat-edge-swipe-access'),
    behavior: HitTestBehavior.translucent,
    onPointerDown: _onPointerDown,
    onPointerMove: _onPointerMove,
    onPointerUp: (_) => _reset(),
    onPointerCancel: (_) => _reset(),
    child: widget.child,
  );

  void _onPointerDown(PointerDownEvent event) {
    _reset();
    if (event.kind != PointerDeviceKind.touch) return;
    final width = MediaQuery.sizeOf(context).width;
    final insets = MediaQuery.systemGestureInsetsOf(context);
    final leftStart = insets.left;
    final rightEnd = width - insets.right;
    if (event.position.dx >= leftStart &&
        event.position.dx <= leftStart + _bandWidth) {
      _candidate = ChatEdgeSwipeAction.history;
    } else if (event.position.dx <= rightEnd &&
        event.position.dx >= rightEnd - _bandWidth) {
      _candidate = ChatEdgeSwipeAction.artifacts;
    }
    if (_candidate != null) _start = event.position;
  }

  void _onPointerMove(PointerMoveEvent event) {
    final start = _start;
    final candidate = _candidate;
    if (start == null || candidate == null || _triggered) return;
    final delta = event.position - start;
    if (delta.distance < _touchSlop) return;
    final directionMatches = candidate == ChatEdgeSwipeAction.history
        ? delta.dx > 0
        : delta.dx < 0;
    if (!directionMatches || delta.dx.abs() < delta.dy.abs() * _dominance) {
      _candidate = null;
      return;
    }
    if (delta.dx.abs() < _threshold) return;
    _triggered = true;
    if (!widget.canPresent()) return;
    if (candidate == ChatEdgeSwipeAction.history) {
      widget.onHistory();
    } else {
      widget.onArtifacts();
    }
  }

  void _reset() {
    _start = null;
    _candidate = null;
    _triggered = false;
  }
}
