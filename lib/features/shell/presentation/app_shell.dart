import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: (index) =>
            shell.goBranch(index, initialLocation: index == shell.currentIndex),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.chat_bubble_outline),
            label: 'nav.chat'.tr(),
          ),
          NavigationDestination(
            icon: const Icon(Icons.hub_outlined),
            label: 'nav.models'.tr(),
          ),
          NavigationDestination(
            icon: const Icon(Icons.folder_copy_outlined),
            label: 'nav.memory'.tr(),
          ),
          NavigationDestination(
            icon: const Icon(Icons.tune),
            label: 'nav.settings'.tr(),
          ),
        ],
      ),
    );
  }
}
