import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// One entry of an [ActionSheet].
class ActionSheetItem<T> {
  const ActionSheetItem({required this.value, required this.label, this.icon, this.subtitle, this.destructive = false, this.enabled = true});

  final T value;
  final String label;
  final IconData? icon;
  final String? subtitle;
  final bool destructive;
  final bool enabled;
}

/// A modal bottom sheet listing actions; returns the chosen value.
class ActionSheet {
  const ActionSheet._();

  static Future<T?> show<T>(BuildContext context, {String? title, required List<ActionSheetItem<T>> items}) {
    return showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) {
        final theme = Theme.of(context);
        final danger = StatusColors.of(context).error;
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(title, style: theme.textTheme.titleMedium),
              ),
            for (final item in items)
              ListTile(
                enabled: item.enabled,
                leading: item.icon == null ? null : Icon(item.icon, color: item.destructive ? danger : null),
                title: Text(item.label, style: item.destructive ? TextStyle(color: danger) : null),
                subtitle: item.subtitle == null ? null : Text(item.subtitle!),
                onTap: () => Navigator.of(context).pop(item.value),
              ),
          ],
        );
      },
    );
  }
}
