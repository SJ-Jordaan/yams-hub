import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'formatters.dart';

/// Thin banner shown while a refresh fails but old data is displayed
/// (ARCHITECTURE §7.7): "Couldn't refresh · showing data from 2 min ago".
class StaleBanner extends StatelessWidget {
  const StaleBanner({super.key, this.since, this.onRetry, this.message});

  /// When the shown data was fetched.
  final DateTime? since;
  final VoidCallback? onRetry;

  /// Overrides the default text.
  final String? message;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final theme = Theme.of(context);
    final text =
        message ??
        (since == null
            ? "Couldn't refresh · showing older data"
            : "Couldn't refresh · showing data from ${formatRelative(since!)}");
    return Material(
      color: colors.warning.withValues(alpha: 0.18),
      child: InkWell(
        onTap: onRetry,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.cloud_off, size: 16, color: colors.warning),
              const SizedBox(width: 8),
              Expanded(child: Text(text, style: theme.textTheme.labelMedium)),
              if (onRetry != null) Icon(Icons.refresh, size: 16, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
