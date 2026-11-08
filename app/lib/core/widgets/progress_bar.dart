import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// A linear progress bar with an optional label above it (left) and a
/// trailing value (right).
class ProgressBar extends StatelessWidget {
  const ProgressBar({super.key, required this.value, this.label, this.trailing, this.tone, this.height = 6});

  /// 0..1; null = indeterminate.
  final double? value;
  final String? label;
  final String? trailing;

  /// Colour of the bar; the theme's primary when null.
  final StatusTone? tone;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tone == null ? theme.colorScheme.primary : StatusColors.of(context).forTone(tone!);
    final v = value?.clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null || trailing != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(label ?? '', style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                ),
                if (trailing != null) Text(trailing!, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(height),
          child: LinearProgressIndicator(
            value: v,
            minHeight: height,
            color: color,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }
}
