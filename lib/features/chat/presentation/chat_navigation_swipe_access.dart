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
    builder: (context, constraints) => RawGestureDetector(
      key: const Key('chat-navigation-swipe-access'),
      behavior: HitTestBehavior.translucent,
      gestures: {
        _NavigationSwipeRecognizer:
            GestureRecognizerFactoryWithHandlers<_NavigationSwipeRecognizer>(
              () => _NavigationSwipeRecognizer(debugOwner: this),
              (recognizer) => recognizer
                ..size = constraints.biggest
                ..isEligible = isEligible
                ..onShowNavigation = onShowNavigation,
            ),
      },
      child: child,
    ),
  );
}

class _NavigationSwipeRecognizer extends OneSequenceGestureRecognizer {
  _NavigationSwipeRecognizer({super.debugOwner});

  static const intentTimeout = Duration(milliseconds: 450);
  static const classifyDistance = 14.0;
  static const commitDistance = 88.0;
  static const fastCommitDistance = 60.0;
  static const fastVelocity = 900.0;
  static const dominance = 1.6;

  Size size = Size.zero;
  bool Function() isEligible = () => false;
  VoidCallback onShowNavigation = () {};

  int? _pointer;
  Offset _drag = Offset.zero;
  VelocityTracker? _velocity;
  Timer? _timer;
  bool _classified = false;
  bool _cancelled = false;
  bool _triggered = false;
  double _furthest = 0;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch || _pointer != null) {
      if (_pointer != null) _cancel();
      resolve(GestureDisposition.rejected);
      return;
    }
    final position = event.localPosition;
    final central =
        position.dx >= size.width * .2 &&
        position.dx <= size.width * .8 &&
        position.dy >= size.height * .3 &&
        position.dy <= size.height * .75;
    if (!central || !isEligible()) {
      resolve(GestureDisposition.rejected);
      return;
    }
    _pointer = event.pointer;
    _drag = Offset.zero;
    _velocity = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
    startTrackingPointer(event.pointer);
    _timer = Timer(intentTimeout, _cancel);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent && !_cancelled) {
      _velocity?.addPosition(event.timeStamp, event.position);
      _drag += event.delta;
      _move(_drag);
      return;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (event is PointerUpEvent && !_cancelled && !_triggered) {
        _velocity?.addPosition(event.timeStamp, event.position);
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
    if (delta.dy > 8 || (_furthest > 0 && upward + 12 < _furthest)) {
      _cancel();
      return;
    }
    if (!_classified) {
      if (horizontal >= 12 && horizontal * dominance > upward) {
        _cancel();
        return;
      }
      if (upward < classifyDistance) return;
      if (upward < horizontal * dominance) {
        _cancel();
        return;
      }
      _classified = true;
      _timer?.cancel();
      _furthest = upward;
      resolve(GestureDisposition.accepted);
    } else {
      _furthest = upward > _furthest ? upward : _furthest;
    }
    final velocity = _velocity?.getVelocity().pixelsPerSecond ?? Offset.zero;
    final fast =
        upward >= fastCommitDistance &&
        velocity.dy <= -fastVelocity &&
        -velocity.dy >= velocity.dx.abs();
    if (upward >= commitDistance || fast) _commit();
  }

  void _commit() {
    if (_triggered || _cancelled) return;
    _triggered = true;
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
    _velocity = null;
    _classified = false;
    _cancelled = false;
    _triggered = false;
    _furthest = 0;
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
