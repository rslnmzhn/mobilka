import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/application/chat_controller.dart';
import 'artifacts_bottom_sheet.dart';

class SessionArtifactsScreen extends ConsumerStatefulWidget {
  const SessionArtifactsScreen({required this.conversationId, super.key});

  final String conversationId;

  @override
  ConsumerState<SessionArtifactsScreen> createState() =>
      _SessionArtifactsScreenState();
}

class _SessionArtifactsScreenState
    extends ConsumerState<SessionArtifactsScreen> {
  var _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatControllerProvider);
    return Scaffold(
      key: const Key('session-artifacts-screen'),
      appBar: AppBar(
        leading: BackButton(
          key: const Key('session-artifacts-back'),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('artifacts.title'.tr()),
      ),
      body: BroadSwipeBack(
        enabled: () => _tabIndex == 0,
        onBack: () => Navigator.of(context).maybePop(),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: chat.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => const _Unavailable(),
              data: (state) {
                final matches = state.conversations.where(
                  (item) => item.id == widget.conversationId,
                );
                if (matches.length != 1) return const _Unavailable();
                return ArtifactSessionTabs(
                  conversation: matches.single,
                  onTabChanged: (index) => _tabIndex = index,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class BroadSwipeBack extends StatelessWidget {
  const BroadSwipeBack({
    required this.child,
    required this.enabled,
    required this.onBack,
    super.key,
  });
  final Widget child;
  final bool Function() enabled;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    key: const Key('broad-swipe-back'),
    behavior: HitTestBehavior.translucent,
    gestures: {
      _BroadBackRecognizer:
          GestureRecognizerFactoryWithHandlers<_BroadBackRecognizer>(
            _BroadBackRecognizer.new,
            (recognizer) => recognizer
              ..enabled = enabled
              ..onBack = onBack,
          ),
    },
    child: child,
  );
}

class _BroadBackRecognizer extends OneSequenceGestureRecognizer {
  bool Function() enabled = () => false;
  VoidCallback onBack = () {};
  int? _pointer;
  Offset? _start;
  bool _accepted = false;
  bool _triggered = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (!enabled() ||
        event.kind != PointerDeviceKind.touch ||
        _pointer != null) {
      resolve(GestureDisposition.rejected);
      return;
    }
    _pointer = event.pointer;
    _start = event.position;
    startTrackingPointer(event.pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      final delta = event.position - _start!;
      if (!_accepted &&
          (delta.dx < -12 ||
              delta.dy.abs() > 18 && delta.dy.abs() > delta.dx.abs() * .65)) {
        resolve(GestureDisposition.rejected);
        stopTrackingPointer(event.pointer);
        _reset();
      } else if (!_accepted && delta.dx >= 8 && delta.dy.abs() < 12) {
        _accepted = true;
        resolve(GestureDisposition.accepted);
      } else if (_accepted &&
          !_triggered &&
          delta.dx >= 110 &&
          delta.dy.abs() <= delta.dx * .5) {
        _triggered = true;
        onBack();
      }
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
      if (!_accepted) resolve(GestureDisposition.rejected);
      _reset();
    }
  }

  void _reset() {
    _pointer = null;
    _start = null;
    _accepted = false;
    _triggered = false;
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}
  @override
  String get debugDescription => 'broad right back';
}

class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('session-artifacts-unavailable'),
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        'artifacts.owner.unavailable'.tr(),
        textAlign: TextAlign.center,
      ),
    ),
  );
}
