import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

enum ChatEdgeSwipeAction { history, artifacts }

@visibleForTesting
class ChatEdgeSwipeAccess extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final insets = MediaQuery.systemGestureInsetsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) => RawGestureDetector(
        key: const Key('chat-edge-swipe-access'),
        behavior: HitTestBehavior.translucent,
        gestures: {
          _ChatSwipeRecognizer:
              GestureRecognizerFactoryWithHandlers<_ChatSwipeRecognizer>(
                () => _ChatSwipeRecognizer(debugOwner: this),
                (recognizer) => recognizer
                  ..width = constraints.maxWidth
                  ..leftInset = insets.left
                  ..rightInset = insets.right
                  ..canPresent = canPresent
                  ..onHistory = onHistory
                  ..onArtifacts = onArtifacts,
              ),
        },
        child: child,
      ),
    );
  }
}

class _ChatSwipeRecognizer extends OneSequenceGestureRecognizer {
  _ChatSwipeRecognizer({super.debugOwner});

  static const classifyDistance = 32.0;
  static const commitDistance = 92.0;
  static const fastCommitDistance = 60.0;
  static const fastVelocity = 900.0;
  static const edgeSafety = 8.0;
  static const intentTimeout = Duration(milliseconds: 450);

  double width = 0;
  double leftInset = 0;
  double rightInset = 0;
  bool Function() canPresent = () => false;
  VoidCallback onHistory = () {};
  VoidCallback onArtifacts = () {};

  int? _pointer;
  Offset? _start;
  ChatEdgeSwipeAction? _action;
  VelocityTracker? _velocity;
  Timer? _timer;
  bool _classified = false;
  bool _cancelled = false;
  bool _triggered = false;
  double _furthest = 0;
  int _initialDirection = 0;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch || _pointer != null) {
      if (_pointer != null) _cancel();
      resolve(GestureDisposition.rejected);
      return;
    }
    final x = event.localPosition.dx;
    if (x <= leftInset + edgeSafety || x >= width - rightInset - edgeSafety) {
      resolve(GestureDisposition.rejected);
      return;
    }
    _pointer = event.pointer;
    _start = event.position;
    _velocity = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
    startTrackingPointer(event.pointer);
    _timer = Timer(intentTimeout, _cancel);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
      if (!_triggered && !_cancelled) resolve(GestureDisposition.rejected);
      _reset();
      return;
    }
    if (_cancelled) return;
    if (event is PointerMoveEvent) {
      _velocity?.addPosition(event.timeStamp, event.position);
      _move(event.position);
    }
  }

  void _move(Offset position) {
    final delta = position - _start!;
    final dx = delta.dx;
    final ax = dx.abs();
    final ay = delta.dy.abs();
    if (!_trackDirection(dx, ax, ay)) return;
    if (!_classified && !_classify(delta, dx, ax, ay)) return;
    if (_classified && !_trackCommittedDirection(dx, ax)) return;

    final velocity = _velocity?.getVelocity().pixelsPerSecond ?? Offset.zero;
    if (_shouldCommit(ax, ay, velocity)) _commit();
  }

  bool _trackDirection(double dx, double ax, double ay) {
    if (_initialDirection == 0 && ax >= 18 && ax > ay) {
      _initialDirection = dx.sign.toInt();
    } else if (_initialDirection != 0 && dx.sign.toInt() != _initialDirection) {
      _cancel();
      return false;
    }
    return true;
  }

  bool _classify(Offset delta, double dx, double ax, double ay) {
    if (!_classified && ay >= 24 && ay > ax * .7) {
      _cancel();
      return false;
    }
    if (delta.distance < classifyDistance) return false;
    if (ax < classifyDistance || ay > ax * .7) {
      _cancel();
      return false;
    }
    _classified = true;
    _timer?.cancel();
    _action = dx > 0
        ? ChatEdgeSwipeAction.history
        : ChatEdgeSwipeAction.artifacts;
    _furthest = ax;
    return true;
  }

  bool _trackCommittedDirection(double dx, double ax) {
    final directionMatches =
        (_action == ChatEdgeSwipeAction.history) == (dx > 0);
    if (!directionMatches || ax + 12 < _furthest) {
      _cancel();
      return false;
    }
    _furthest = ax > _furthest ? ax : _furthest;
    return true;
  }

  bool _shouldCommit(double ax, double ay, Offset velocity) {
    final fast =
        ax >= fastCommitDistance &&
        velocity.dx.abs() >= fastVelocity &&
        velocity.dx.abs() >= velocity.dy.abs() &&
        ay <= ax;
    return ax >= commitDistance && ay <= ax * .7 || fast;
  }

  void _commit() {
    if (_triggered || _cancelled) return;
    _triggered = true;
    resolve(GestureDisposition.accepted);
    if (!canPresent()) return;
    _action == ChatEdgeSwipeAction.history ? onHistory() : onArtifacts();
  }

  void _cancel() {
    if (_triggered || _cancelled) return;
    _cancelled = true;
    resolve(GestureDisposition.rejected);
  }

  void _reset() {
    _timer?.cancel();
    _pointer = null;
    _start = null;
    _action = null;
    _velocity = null;
    _classified = false;
    _cancelled = false;
    _triggered = false;
    _furthest = 0;
    _initialDirection = 0;
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'chat broad swipe';

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
