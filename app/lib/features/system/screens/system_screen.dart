/// `/system` (APP.md §12): host, storage, network, Uptime Kuma and service
/// health. Host every 5 s, uptime and health every 30 s.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/servers/server_config_provider.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/system_providers.dart';
import '../widgets/host_card.dart';
import '../widgets/service_health_card.dart';
import '../widgets/storage_network_cards.dart';
import '../widgets/uptime_card.dart';

class SystemScreen extends ConsumerWidget {
  const SystemScreen({super.key});

  /// Two columns from this width on (tablet landscape, web).
  static const wideBreakpoint = 1000.0;

  Future<void> _refresh(WidgetRef ref) async {
    ref
      ..invalidate(hostMetricsProvider)
      ..invalidate(uptimeProvider)
      ..invalidate(healthProvider)
      ..invalidate(hostHistoryProvider);
    await Future.wait<Object?>([
      ref.read(hostMetricsProvider.future).then<Object?>((v) => v, onError: (Object _) => null),
      ref.read(uptimeProvider.future).then<Object?>((v) => v, onError: (Object _) => null),
      ref.read(healthProvider.future).then<Object?>((v) => v, onError: (Object _) => null),
    ]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(hostMetricsProvider);
    final staleHost = host.hasError && host.hasValue;
    return Scaffold(
      appBar: AppBar(title: const Text('System')),
      body: Column(
        children: [
          if (staleHost) StaleBanner(since: host.value!.sampledAt, onRetry: () => ref.invalidate(hostMetricsProvider)),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _refresh(ref),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final hostCards = _hostCards(ref, host);
                  const uptime = _UptimeSection();
                  const health = _HealthSection();
                  if (constraints.maxWidth >= wideBreakpoint) {
                    return ListView(
                      padding: const EdgeInsets.all(12),
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: _column([hostCards.first])),
                            const SizedBox(width: 8),
                            Expanded(child: _column([...hostCards.skip(1), uptime, health])),
                          ],
                        ),
                      ],
                    );
                  }
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      for (final c in [...hostCards, uptime, health]) ...[c, const SizedBox(height: 4)],
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _column(List<Widget> cards) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final c in cards) ...[c, const SizedBox(height: 4)],
    ],
  );

  /// Host, Storage and Network (all from `GET /system/host`).
  List<Widget> _hostCards(WidgetRef ref, AsyncValue<HostMetrics> host) {
    if (host.value case final m?) {
      return [HostCard(metrics: m), StorageCard(metrics: m), NetworkCard(metrics: m)];
    }
    if (host.hasError) {
      return [
        SectionCard(
          title: 'Host',
          icon: Icons.memory,
          child: ErrorView(error: host.error!, compact: true, onRetry: () => ref.invalidate(hostMetricsProvider)),
        ),
      ];
    }
    return const [
      _SkeletonCard(title: 'Host', icon: Icons.memory, lines: 6),
      _SkeletonCard(title: 'Storage', icon: Icons.storage, lines: 3),
      _SkeletonCard(title: 'Network', icon: Icons.lan_outlined, lines: 2),
    ];
  }
}

class _UptimeSection extends ConsumerWidget {
  const _UptimeSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uptime = ref.watch(uptimeProvider);
    return _AsyncCard(
      title: 'Uptime',
      icon: Icons.monitor_heart_outlined,
      value: uptime,
      onRetry: () => ref.invalidate(uptimeProvider),
      data: (u) => UptimeContent(uptime: u),
    );
  }
}

class _HealthSection extends ConsumerWidget {
  const _HealthSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(healthProvider);
    return _AsyncCard(
      title: 'Service health',
      icon: Icons.health_and_safety_outlined,
      value: health,
      onRetry: () => ref.invalidate(healthProvider),
      data: (r) => ServiceHealthContent(report: r),
    );
  }
}

/// A [SectionCard] with the loading / error / stale states of one provider.
class _AsyncCard<T> extends StatelessWidget {
  const _AsyncCard({
    required this.title,
    required this.icon,
    required this.value,
    required this.onRetry,
    required this.data,
  });

  final String title;
  final IconData icon;
  final AsyncValue<T> value;
  final VoidCallback onRetry;
  final Widget Function(T data) data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = value;
    final Widget child;
    if (v.hasValue) {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (v.hasError)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(Icons.cloud_off, size: 14, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      "Couldn't refresh · showing older data",
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          data(v.value as T),
        ],
      );
    } else if (v.hasError) {
      child = ErrorView(error: v.error!, compact: true, onRetry: onRetry);
    } else {
      child = const _SkeletonLines(lines: 5);
    }
    return SectionCard(title: title, icon: icon, child: child);
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard({required this.title, required this.icon, required this.lines});

  final String title;
  final IconData icon;
  final int lines;

  @override
  Widget build(BuildContext context) => SectionCard(
    title: title,
    icon: icon,
    child: _SkeletonLines(lines: lines),
  );
}

class _SkeletonLines extends StatelessWidget {
  const _SkeletonLines({required this.lines});

  final int lines;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < lines; i++) ...[
        if (i > 0) const SizedBox(height: 10),
        FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: i.isEven ? 1 : 0.6,
          child: const SkeletonBox(height: 14),
        ),
      ],
    ],
  );
}
