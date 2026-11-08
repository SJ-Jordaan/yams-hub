/// `/home`: alerts, feature cards and the web-apps section (APP.md §3.3).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_controller.dart';
import '../launcher/web_apps_section.dart';
import '../routing/paths.dart';
import '../servers/hosting.dart';
import '../servers/network_kind.dart';
import '../servers/server_connection.dart';
import '../settings/app_settings.dart';
import '../widgets/error_view.dart';
import '../widgets/formatters.dart';
import '../widgets/skeleton.dart';
import '../widgets/stale_banner.dart';
import 'alerts_panel.dart';
import 'dashboard_card_frame.dart';
import 'dashboard_cards.dart';
import 'dashboard_providers.dart';

/// Number of masonry columns for a width (1 < 600 dp, 2 < 1200 dp, else 3).
int dashboardColumnsFor(double width) => width < 600 ? 1 : (width < 1200 ? 2 : 3);

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dashboard = ref.watch(dashboardProvider);
    final order = ref.watch(appSettingsProvider.select((s) => s.visibleCards));
    final data = dashboard.value;

    Future<void> refresh() async {
      ref.invalidate(dashboardProvider);
      try {
        await ref.read(dashboardProvider.future);
      } catch (_) {
        // Shown by the screen.
      }
    }

    final Widget body;
    if (data == null && dashboard.hasError) {
      body = ErrorView(
        error: dashboard.error!,
        onRetry: refresh,
        actions: [
          if (ref.watch(hostingModeProvider).hasServerProfiles)
            OutlinedButton(onPressed: () => context.go(AppPaths.settingsServers()), child: const Text('Server settings')),
        ],
      );
    } else {
      body = RefreshIndicator(
        onRefresh: refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (data != null && dashboard.hasError)
              SliverToBoxAdapter(child: StaleBanner(since: data.generatedAt, onRetry: refresh)),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              sliver: SliverToBoxAdapter(child: _Header(updatedAt: data?.generatedAt)),
            ),
            if (data != null && data.alerts.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverToBoxAdapter(child: AlertsPanel(alerts: data.alerts)),
              ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: data == null
                    ? const _CardsSkeleton()
                    : _CardMasonry(
                        children: [
                          for (final key in order)
                            if (dashboardCards[key] case final spec?)
                              if (data.card(key) case final section?)
                                DashboardCardFrame(spec: spec, section: section, onRetry: refresh),
                        ],
                      ),
              ),
            ),
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverToBoxAdapter(child: WebAppsSection()),
            ),
          ],
        ),
      );
    }
    return Scaffold(body: SafeArea(bottom: false, child: body));
  }
}

class _Header extends ConsumerWidget {
  const _Header({this.updatedAt});

  final DateTime? updatedAt;

  static String greeting(DateTime now) {
    final h = now.hour;
    if (h < 5) return 'Good night';
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final user = ref.watch(authControllerProvider.select((s) => s.user));
    final connection = ref.watch(activeServerProvider);
    final name = user?.displayName;
    final hello = greeting(DateTime.now());
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        Text(name == null || name.isEmpty ? hello : '$hello, $name', style: theme.textTheme.headlineSmall),
        _ServerChip(connection: connection),
        if (updatedAt != null)
          Text(
            'Updated ${formatRelative(updatedAt)}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
  }
}

class _ServerChip extends StatelessWidget {
  const _ServerChip({required this.connection});

  final ServerConnection connection;

  @override
  Widget build(BuildContext context) {
    final url = connection.baseUrl;
    if (url == null) return const SizedBox.shrink();
    final kind = connection.networkKind ?? NetworkKind.internet;
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(kind == NetworkKind.tailscale ? Icons.vpn_lock : Icons.lan_outlined, size: 16),
      label: Text('${kind.label} · ${url.host}'),
    );
  }
}

/// Distributes [children] over 1–3 columns, filling them in order.
class _CardMasonry extends StatelessWidget {
  const _CardMasonry({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = dashboardColumnsFor(constraints.maxWidth);
        if (columns == 1) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, c) in children.indexed) ...[if (i > 0) const SizedBox(height: 12), c],
            ],
          );
        }
        final buckets = List.generate(columns, (_) => <Widget>[]);
        for (final (i, c) in children.indexed) {
          buckets[i % columns].add(c);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, bucket) in buckets.indexed) ...[
              if (i > 0) const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (j, c) in bucket.indexed) ...[if (j > 0) const SizedBox(height: 12), c],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _CardsSkeleton extends StatelessWidget {
  const _CardsSkeleton();

  @override
  Widget build(BuildContext context) {
    return _CardMasonry(
      children: [for (final h in [160.0, 120.0, 140.0, 120.0]) SkeletonBox(height: h, radius: 16)],
    );
  }
}
