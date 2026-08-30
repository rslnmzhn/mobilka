import 'package:flutter/widgets.dart';

import 'chat_navigation_controller.dart';

class ShellNavigationScope extends InheritedWidget {
  const ShellNavigationScope({
    required this.controller,
    required this.chatNavigationVisible,
    required super.child,
    super.key,
  });

  final ChatNavigationController controller;

  final bool chatNavigationVisible;
  VoidCallback get showNavigation => controller.show;
  VoidCallback get hideNavigation => controller.hide;

  static ShellNavigationScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellNavigationScope>();

  @override
  bool updateShouldNotify(ShellNavigationScope oldWidget) =>
      chatNavigationVisible != oldWidget.chatNavigationVisible ||
      controller != oldWidget.controller;
}
