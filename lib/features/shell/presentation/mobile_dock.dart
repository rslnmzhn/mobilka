import 'package:flutter/material.dart';

class MobileDock extends StatelessWidget {
  const MobileDock({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<(IconData, IconData, String)> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) => NavigationBar(
    height: 52,
    selectedIndex: selectedIndex,
    onDestinationSelected: onSelect,
    labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
    destinations: destinations
        .map(
          (destination) => NavigationDestination(
            icon: Icon(destination.$1),
            selectedIcon: Icon(destination.$2),
            label: destination.$3,
          ),
        )
        .toList(),
  );
}
