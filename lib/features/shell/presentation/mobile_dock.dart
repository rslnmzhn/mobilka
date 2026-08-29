import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

const mobileDockIndicatorKey = Key('mobile-dock-indicator');
const mobileDockHideKey = Key('mobile-dock-hide');

class MobileDock extends StatelessWidget {
  const MobileDock({
    super.key,
    required this.expanded,
    required this.canCollapse,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelect,
    required this.onShow,
    required this.onHide,
  });

  final bool expanded;
  final bool canCollapse;
  final List<(IconData, IconData, String)> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onShow;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<WorkbenchColors>();
    final divider = colors?.divider ?? theme.dividerColor;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);

    final media = MediaQuery.of(context);
    final reservedBottom = math.max(
      media.padding.bottom,
      media.systemGestureInsets.bottom,
    );

    return Padding(
      padding: EdgeInsets.only(
        bottom: media.viewInsets.bottom + reservedBottom,
      ),
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(top: BorderSide(color: divider, width: 0.7)),
          ),
          child: AnimatedSize(
            duration: duration,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: expanded
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (canCollapse)
                        _DockControl(
                          key: mobileDockHideKey,
                          label: 'nav.hide'.tr(),
                          hint: 'nav.hideHint'.tr(),
                          onPressed: onHide,
                          onSwipe: onHide,
                          swipeDown: true,
                        ),
                      NavigationBar(
                        height: 52,
                        selectedIndex: selectedIndex,
                        onDestinationSelected: onSelect,
                        labelBehavior:
                            NavigationDestinationLabelBehavior.alwaysHide,
                        destinations: destinations
                            .map(
                              (destination) => NavigationDestination(
                                icon: Icon(destination.$1),
                                selectedIcon: Icon(destination.$2),
                                label: destination.$3,
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  )
                : _DockControl(
                    key: mobileDockIndicatorKey,
                    label: 'nav.show'.tr(),
                    hint: 'nav.showHint'.tr(),
                    onPressed: onShow,
                    onSwipe: onShow,
                    swipeDown: false,
                  ),
          ),
        ),
      ),
    );
  }
}

class _DockControl extends StatefulWidget {
  const _DockControl({
    super.key,
    required this.label,
    required this.hint,
    required this.onPressed,
    required this.onSwipe,
    required this.swipeDown,
  });

  final String label;
  final String hint;
  final VoidCallback onPressed;
  final VoidCallback onSwipe;
  final bool swipeDown;

  @override
  State<_DockControl> createState() => _DockControlState();
}

class _DockControlState extends State<_DockControl> {
  Offset _drag = Offset.zero;

  void _start(DragStartDetails details) => _drag = Offset.zero;

  void _update(DragUpdateDetails details) => _drag += details.delta;

  void _end(DragEndDetails details) {
    final vertical = widget.swipeDown ? _drag.dy : -_drag.dy;
    if (vertical >= 40 && vertical > _drag.dx.abs()) {
      widget.onSwipe();
    }
    _drag = Offset.zero;
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      label: widget.label,
      hint: widget.hint,
      onTap: widget.onPressed,
      child: Tooltip(
        message: widget.label,
        excludeFromSemantics: true,
        child: GestureDetector(
          onVerticalDragStart: _start,
          onVerticalDragUpdate: _update,
          onVerticalDragEnd: _end,
          child: InkWell(
            onTap: widget.onPressed,
            excludeFromSemantics: true,
            autofocus: true,
            child: SizedBox(
              height: 48,
              width: double.infinity,
              child: Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
