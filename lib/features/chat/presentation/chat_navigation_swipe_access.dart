import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

@visibleForTesting
class ChatNavigationSwipeAccess extends StatelessWidget {
  const ChatNavigationSwipeAccess({
    required this.child,
    required this.isEligible,
    required this.onShowNavigation,
    super.key,
  });

  final Widget child;
  final bool Function() isEligible;
  final VoidCallback onShowNavigation;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final gestureInsets = MediaQuery.systemGestureInsetsOf(context);
      return RawGestureDetector(
        key: const Key('chat-navigation-swipe-access'),
        behavior: HitTestBehavior.translucent,
        gestures: {
          _NavigationSwipeRecognizer:
              GestureRecognizerFactoryWithHandlers<_NavigationSwipeRecognizer>(
                () => _NavigationSwipeRecognizer(debugOwner: this),
                (recognizer) => recognizer
                  ..size = constraints.biggest
                  ..excludedLeft = gestureInsets.left.clamp(16, double.infinity)
                  ..excludedRight = gestureInsets.right.clamp(
                    16,
                    double.infinity,
                  )
                  ..isEligible = isEligible
                  ..onShowNavigation = onShowNavigation,
              ),
        },
        child: child,
      );
    },
  );
}

class _NavigationSwipeRecognizer extends OneSequenceGestureRecognizer {
  _NavigationSwipeRecognizer({super.debugOwner});

  static const intentTimeout = Duration(milliseconds: 450);
  static const classifyDistance = 14.0;
  static const dominance = 1.6;

  Size size = Size.zero;
  double excludedLeft = 16;
  double excludedRight = 16;
  bool Function() isEligible = () => false;
  VoidCallback onShowNavigation = () {};

  int? _pointer;
  Offset _drag = Offset.zero;
  Timer? _timer;
  bool _cancelled = false;
  bool _triggered = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch || _pointer != null) {
      if (_pointer != null) _cancel();
      resolve(GestureDisposition.rejected);
      return;
    }
    final position = event.localPosition;
    final insideHorizontalBounds =
        position.dx >= excludedLeft &&
        position.dx <= size.width - excludedRight;
    if (!insideHorizontalBounds || !isEligible()) {
      resolve(GestureDisposition.rejected);
      return;
    }
    _pointer = event.pointer;
    _drag = Offset.zero;
    startTrackingPointer(event.pointer);
    _timer = Timer(intentTimeout, _cancel);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent && !_cancelled) {
      _drag += event.delta;
      _move(_drag);
      return;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (event is PointerUpEvent && !_cancelled && !_triggered) {
        _drag += event.delta;
        _move(_drag);
      }
      stopTrackingPointer(event.pointer);
      if (!_triggered && !_cancelled) resolve(GestureDisposition.rejected);
      _reset();
    }
  }

  void _move(Offset delta) {
    final upward = -delta.dy;
    final horizontal = delta.dx.abs();
    if (delta.dy > 8) {
      _cancel();
      return;
    }
    if (horizontal >= 12 && horizontal * dominance > upward) {
      _cancel();
      return;
    }
    if (upward < classifyDistance || _triggered) return;
    if (upward < horizontal * dominance) {
      _cancel();
      return;
    }
    _timer?.cancel();
    _triggered = true;
    resolve(GestureDisposition.accepted);
    if (isEligible()) onShowNavigation();
  }

  void _cancel() {
    if (_triggered || _cancelled) return;
    _cancelled = true;
    resolve(GestureDisposition.rejected);
  }

  void _reset() {
    _timer?.cancel();
    _pointer = null;
    _drag = Offset.zero;
    _cancelled = false;
    _triggered = false;
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'chat navigation upward swipe';

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
