import 'package:flutter/material.dart';

import 'app_theme.dart';

class WorkbenchPageTitle extends StatelessWidget {
  const WorkbenchPageTitle({
    required this.icon,
    required this.title,
    this.detail,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<WorkbenchColors>();
    return Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            border: Border.all(color: colors?.divider ?? theme.dividerColor),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 17, color: theme.colorScheme.primary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (detail != null)
                Text(
                  detail!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors?.mutedInk,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.8,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class WorkbenchSectionLabel extends StatelessWidget {
  const WorkbenchSectionLabel({required this.label, this.icon, super.key});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<WorkbenchColors>();
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: theme.colorScheme.primary),
            const SizedBox(width: 7),
          ],
          Flexible(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors?.mutedInk,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.3,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Divider(color: colors?.divider ?? theme.dividerColor),
          ),
        ],
      ),
    );
  }
}

class WorkbenchBody extends StatelessWidget {
  const WorkbenchBody({
    required this.child,
    this.maxWidth = 960,
    this.padding = const EdgeInsets.fromLTRB(20, 16, 20, 28),
    super.key,
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Padding(padding: padding, child: child),
    ),
  );
}
