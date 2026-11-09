import 'package:flutter/material.dart';
import 'package:yams_models/yams_models.dart';

import '../api/api_exception.dart';

/// Full error state for a failed first load (APP.md §2.1): an icon chosen by
/// error code, the message, the service and a Retry button.
/// `service_not_configured` shows "Not configured on the hub" without retry.
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry, this.compact = false, this.actions = const []});

  /// Anything thrown by an API call (converted with [ApiException.from]).
  final Object error;
  final VoidCallback? onRetry;

  /// Smaller layout for cards.
  final bool compact;

  /// Extra buttons (e.g. "Server settings").
  final List<Widget> actions;

  static IconData iconFor(ApiException e) {
    if (e.isNetwork) return Icons.wifi_off;
    return switch (e.code) {
      ApiErrorCode.upstreamUnavailable || ApiErrorCode.upstreamTimeout => Icons.cloud_off,
      ApiErrorCode.serviceNotConfigured => Icons.settings,
      ApiErrorCode.upstreamHostRejected => Icons.dns_outlined,
      ApiErrorCode.forbidden || ApiErrorCode.policyDenied => Icons.lock_outline,
      ApiErrorCode.notFound => Icons.search_off,
      ApiErrorCode.notImplemented => Icons.construction_outlined,
      ClientErrorCode.resultUnknown => Icons.help_outline,
      _ => Icons.error_outline,
    };
  }

  static String titleFor(ApiException e) {
    if (e.isNotConfigured) return 'Not configured on the hub';
    if (e.isNotImplemented) return 'Not available yet';
    if (e.isNetwork) return "Can't reach the hub";
    if (e.isHostRejected) return "${e.service?.displayName ?? 'The service'} blocks the hub";
    return 'Something went wrong';
  }

  @override
  Widget build(BuildContext context) {
    final e = ApiException.from(error);
    final theme = Theme.of(context);
    final canRetry = onRetry != null && !e.isNotConfigured && !e.isNotImplemented;
    final service = e.service;
    final detail = [
      if (e.message.isNotEmpty && e.message != titleFor(e)) e.message,
      // The host-rejected message already names the service.
      if (service != null && service != ServiceId.unknown && !e.isHostRejected) service.displayName,
    ].join(' · ');

    final children = <Widget>[
      Icon(iconFor(e), size: compact ? 28 : 48, color: theme.colorScheme.onSurfaceVariant),
      SizedBox(height: compact ? 8 : 16),
      Text(
        titleFor(e),
        style: compact ? theme.textTheme.titleSmall : theme.textTheme.titleMedium,
        textAlign: TextAlign.center,
      ),
      if (detail.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(
          detail,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ],
      if (canRetry || actions.isNotEmpty) ...[
        SizedBox(height: compact ? 8 : 20),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            if (canRetry)
              compact
                  ? TextButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Retry'))
                  : FilledButton.tonalIcon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Retry')),
            ...actions,
          ],
        ),
      ],
    ];

    final column = Column(mainAxisSize: MainAxisSize.min, children: children);
    if (compact) return Padding(padding: const EdgeInsets.all(12), child: Center(child: column));
    return Center(child: SingleChildScrollView(padding: const EdgeInsets.all(32), child: column));
  }
}
