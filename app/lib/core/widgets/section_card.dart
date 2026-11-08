import 'package:flutter/material.dart';

/// A titled card: title (with optional icon), trailing action and content.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.title,
    this.icon,
    this.trailing,
    this.onTap,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
  });

  final String? title;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null || trailing != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(title ?? '', style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                    ),
                    ?trailing,
                  ],
                ),
              )
            else
              const SizedBox(height: 16),
            Padding(padding: padding, child: child),
          ],
        ),
      ),
    );
  }
}
