import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'error_view.dart';
import 'skeleton.dart';
import 'stale_banner.dart';

/// Renders an [AsyncValue] with the global state rules (APP.md §2.1,
/// ARCHITECTURE §7.7):
/// - first load: [loading] (a skeleton shaped like the content);
/// - first load failed: [ErrorView] with Retry;
/// - data: [data]; when a refresh failed but data exists, the data stays and a
///   [StaleBanner] is shown above it.
///
/// Needs a bounded height when the stale banner can appear (full-screen
/// bodies); pass `showStaleBanner: false` inside scroll views and cards.
class AsyncValueView<T> extends StatelessWidget {
  const AsyncValueView({
    super.key,
    required this.value,
    required this.data,
    this.loading,
    this.onRetry,
    this.errorActions = const [],
    this.fetchedAt,
    this.showStaleBanner = true,
    this.compactError = false,
  });

  final AsyncValue<T> value;
  final Widget Function(BuildContext context, T data) data;

  /// First-load placeholder; defaults to a list skeleton.
  final Widget? loading;

  /// Retry (first-load error) and tap-to-retry on the stale banner.
  final VoidCallback? onRetry;
  final List<Widget> errorActions;

  /// When the shown data was fetched (for the stale banner text).
  final DateTime? fetchedAt;
  final bool showStaleBanner;
  final bool compactError;

  @override
  Widget build(BuildContext context) {
    final v = value;
    if (v.hasValue) {
      final child = data(context, v.value as T);
      if (v.hasError && showStaleBanner) {
        return Column(
          children: [
            StaleBanner(since: fetchedAt, onRetry: onRetry),
            Expanded(child: child),
          ],
        );
      }
      return child;
    }
    if (v.hasError) {
      return ErrorView(error: v.error!, onRetry: onRetry, actions: errorActions, compact: compactError);
    }
    return loading ?? const SkeletonList();
  }
}
