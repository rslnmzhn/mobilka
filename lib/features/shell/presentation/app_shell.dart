import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import 'mobile_dock.dart';
import 'shell_navigation_scope.dart';

const double compactShellBreakpoint = 760;
const double expandedShellBreakpoint = 1100;

bool isZeroFootprintChatPath(String path) => path == '/chat';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.shell, required this.currentPath});

  final StatefulNavigationShell shell;
  final String currentPath;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _presentingNavigation = false;

  bool get _isChatRoot => isZeroFootprintChatPath(widget.currentPath);

  @override
  Widget build(BuildContext context) {
    final destinations = [
      (Icons.chat_bubble_outline, Icons.chat_bubble, 'nav.chat'.tr()),
      (Icons.hub_outlined, Icons.hub, 'nav.models'.tr()),
      (Icons.smart_toy_outlined, Icons.smart_toy, 'nav.agents'.tr()),
      (Icons.folder_copy_outlined, Icons.folder_copy, 'nav.memory'.tr()),
      (Icons.tune_outlined, Icons.tune, 'nav.settings'.tr()),
    ];
    void select(int index) {
      widget.shell.goBranch(
        index,
        initialLocation: index == widget.shell.currentIndex,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= expandedShellBreakpoint) {
          return _DesktopFrame(
            navigation: _ExpandedNavigation(
              destinations: destinations,
              selectedIndex: widget.shell.currentIndex,
              onSelect: select,
            ),
            child: widget.shell,
          );
        }
        if (constraints.maxWidth >= compactShellBreakpoint) {
          return _DesktopFrame(
            navigation: NavigationRail(
              backgroundColor: Colors.transparent,
              selectedIndex: widget.shell.currentIndex,
              onDestinationSelected: select,
              labelType: NavigationRailLabelType.none,
              groupAlignment: -0.72,
              leading: const Padding(
                padding: EdgeInsets.only(top: 12, bottom: 22),
                child: _MobilkaMark(),
              ),
              destinations: destinations
                  .map(
                    (destination) => NavigationRailDestination(
                      icon: Icon(destination.$1),
                      selectedIcon: Icon(destination.$2),
                      label: Text(destination.$3),
                    ),
                  )
                  .toList(),
            ),
            child: widget.shell,
          );
        }
        return Scaffold(
          body: ShellNavigationScope(
            showNavigation: _isChatRoot
                ? () => _showNavigation(destinations, select)
                : null,
            child: widget.shell,
          ),
          bottomNavigationBar: _isChatRoot
              ? null
              : MobileDock(
                  destinations: destinations,
                  selectedIndex: widget.shell.currentIndex,
                  onSelect: select,
                ),
        );
      },
    );
  }

  Future<void> _showNavigation(
    List<(IconData, IconData, String)> destinations,
    ValueChanged<int> select,
  ) async {
    if (_presentingNavigation || !_isChatRoot || !mounted) return;
    if (MediaQuery.sizeOf(context).width >= compactShellBreakpoint) return;
    _presentingNavigation = true;
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final selected = await showModalBottomSheet<int>(
        context: context,
        useSafeArea: true,
        showDragHandle: false,
        builder: (context) => _MobileNavigationSheet(
          destinations: destinations,
          selectedIndex: widget.shell.currentIndex,
        ),
      );
      if (selected != null && selected != 0 && mounted) select(selected);
    } finally {
      _presentingNavigation = false;
    }
  }
}

class _MobileNavigationSheet extends StatelessWidget {
  const _MobileNavigationSheet({
    required this.destinations,
    required this.selectedIndex,
  });

  final List<(IconData, IconData, String)> destinations;
  final int selectedIndex;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: NavigationBar(
        height: 64,
        selectedIndex: selectedIndex,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
        onDestinationSelected: (index) => Navigator.pop(context, index),
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
    ),
  );
}

class _DesktopFrame extends StatelessWidget {
  const _DesktopFrame({required this.navigation, required this.child});

  final Widget navigation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = _workbench(context);
    return Scaffold(
      backgroundColor: colors.sidebar,
      body: SafeArea(
        child: Row(
          children: [
            navigation,
            VerticalDivider(color: colors.divider),
            Expanded(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpandedNavigation extends StatelessWidget {
  const _ExpandedNavigation({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<(IconData, IconData, String)> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = _workbench(context);
    return SizedBox(
      width: 224,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 20, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _WorkbenchBrand(),
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                'WORKSPACE',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.mutedInk,
                ),
              ),
            ),
            const SizedBox(height: 8),
            for (var index = 0; index < destinations.length; index++)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: ListTile(
                  dense: true,
                  minTileHeight: 42,
                  selected: selectedIndex == index,
                  selectedTileColor: theme.colorScheme.primary.withValues(
                    alpha: 0.10,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  leading: Icon(
                    selectedIndex == index
                        ? destinations[index].$2
                        : destinations[index].$1,
                    size: 20,
                  ),
                  title: Text(destinations[index].$3),
                  onTap: () => onSelect(index),
                ),
              ),
            const Spacer(),
            Divider(color: colors.divider),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 2),
              child: Text(
                'REMOTE AGENT WORKSPACE',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.mutedInk,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkbenchBrand extends StatelessWidget {
  const _WorkbenchBrand();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        _MobilkaMark(),
        SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'MOBILKA',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                ),
              ),
              Text(
                'Workbench',
                style: TextStyle(fontFamily: 'serif', fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MobilkaMark extends StatelessWidget {
  const _MobilkaMark();

  static const markKey = Key('mobilka-brand-mark');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: markKey,
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        'M',
        style: TextStyle(
          color: scheme.onPrimary,
          fontFamily: 'serif',
          fontWeight: FontWeight.w700,
          fontSize: 18,
        ),
      ),
    );
  }
}

WorkbenchColors _workbench(BuildContext context) {
  final theme = Theme.of(context);
  return theme.extension<WorkbenchColors>() ??
      WorkbenchColors(
        canvas: theme.scaffoldBackgroundColor,
        sidebar: theme.colorScheme.surface,
        divider: theme.dividerColor,
        mutedInk: theme.colorScheme.onSurfaceVariant,
      );
}
