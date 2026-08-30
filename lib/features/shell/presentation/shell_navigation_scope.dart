import 'package:flutter/widgets.dart';

class ShellNavigationScope extends InheritedWidget {
  const ShellNavigationScope({
    required this.showNavigation,
    required super.child,
    super.key,
  });

  final Future<void> Function()? showNavigation;

  static Future<void> Function()? maybeShowNavigation(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ShellNavigationScope>()
          ?.showNavigation;

  @override
  bool updateShouldNotify(ShellNavigationScope oldWidget) =>
      showNavigation != oldWidget.showNavigation;
}
