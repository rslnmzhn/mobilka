import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    final destinations = [
      (Icons.chat_bubble_outline, 'nav.chat'.tr()),
      (Icons.hub_outlined, 'nav.models'.tr()),
      (Icons.smart_toy_outlined, 'nav.agents'.tr()),
      (Icons.folder_copy_outlined, 'nav.memory'.tr()),
      (Icons.tune, 'nav.settings'.tr()),
    ];
    void select(int index) =>
        shell.goBranch(index, initialLocation: index == shell.currentIndex);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 840) {
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: shell.currentIndex,
                  onDestinationSelected: select,
                  labelType: NavigationRailLabelType.all,
                  destinations: destinations
                      .map(
                        (destination) => NavigationRailDestination(
                          icon: Icon(destination.$1),
                          label: Text(destination.$2),
                        ),
                      )
                      .toList(),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: shell),
              ],
            ),
          );
        }
        return Scaffold(
          body: shell,
          bottomNavigationBar: NavigationBar(
            selectedIndex: shell.currentIndex,
            onDestinationSelected: select,
            destinations: destinations
                .map(
                  (destination) => NavigationDestination(
                    icon: Icon(destination.$1),
                    label: destination.$2,
                  ),
                )
                .toList(),
          ),
        );
      },
    );
  }
}
