/// `/home`: alerts, feature cards and the web-apps section (APP.md §3.3).
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_models/yams_models.dart';

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

/// What [DashboardScreen] lays out: which cards exist and whether there is
/// data, an error or alerts. Card contents are watched by the cards.
typedef _DashboardLayout = ({bool hasData, Object? error, String keys, bool hasAlerts, DateTime? staleSince});

_DashboardLayout _layoutOf(AsyncValue<DashboardResponse> s) {
  final data = s.value;
  return (
    hasData: data != null,
    error: s.hasError ? s.error : null,
    keys: data?.cards.keys.join(',') ?? '',
    hasAlerts: data?.alerts.isNotEmpty ?? false,
    staleSince: s.hasError ? data?.generatedAt : null,
  );
}

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  /// The scroll view's cache extent once the first frame is out: the cards
  /// below the fold are then built a few at a time (one step per frame) and
  /// kept, so scrolling does not build them.
  static const prebuildExtent = 4000.0;

  /// How far the cache extent grows per frame: about one card, so no frame
  /// builds more than one or two cards on a phone.
  static const prebuildStep = 250.0;

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  /// Starts at zero, so the first frame builds only what is visible.
  double _cacheExtent = 0;
  bool _growScheduled = false;

  void _scheduleGrow() {
    if (_growScheduled || _cacheExtent >= DashboardScreen.prebuildExtent) return;
    _growScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _growScheduled = false;
      if (!mounted) return;
      setState(() {
        _cacheExtent = (_cacheExtent + DashboardScreen.prebuildStep).clamp(0, DashboardScreen.prebuildExtent);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final layout = ref.watch(dashboardProvider.select(_layoutOf));
    // Joined so the comparison is by value.
    final order = ref.watch(appSettingsProvider.select((s) => s.visibleCards.join(',')));
    final present = layout.keys.split(',').toSet();
    final keys = [
      for (final key in order.split(','))
        if (dashboardCards.containsKey(key) && present.contains(key)) key,
    ];

    Future<void> refresh() => refreshDashboard(ref);

    final Widget body;
    final error = layout.error;
    if (!layout.hasData && error != null) {
      body = ErrorView(
        error: error,
        onRetry: refresh,
        actions: [
          if (ref.watch(hostingModeProvider).hasServerProfiles)
            OutlinedButton(
              onPressed: () => context.go(AppPaths.settingsServers()),
              child: const Text('Server settings'),
            ),
        ],
      );
    } else {
      if (layout.hasData) _scheduleGrow();
      body = RefreshIndicator(
        onRefresh: refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          scrollCacheExtent: ScrollCacheExtent.pixels(_cacheExtent),
          slivers: [
            if (layout.staleSince case final since?)
              SliverToBoxAdapter(
                child: StaleBanner(since: since, onRetry: refresh),
              ),
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              sliver: SliverToBoxAdapter(child: _Header()),
            ),
            if (layout.hasAlerts)
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverToBoxAdapter(child: AlertsPanel()),
              ),
            if (layout.hasData)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                sliver: _DashboardCards(keys: keys),
              )
            else
              const SliverPadding(
                padding: EdgeInsets.all(16),
                sliver: SliverToBoxAdapter(child: _CardsSkeleton()),
              ),
          ],
        ),
      );
    }
    return Scaffold(body: SafeArea(bottom: false, child: body));
  }
}

/// The feature cards, then the web apps.
///
/// On one column this is a lazy list: only the cards in and near the viewport
/// are built (each behind a repaint boundary), and the web apps (with their
/// providers) only once scrolled near. Wider layouts use the masonry, each
/// card behind its own repaint boundary.
class _DashboardCards extends StatelessWidget {
  const _DashboardCards({required this.keys});

  final List<String> keys;

  /// Space between the last card and the web apps.
  static const _webAppsGap = 16.0;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        if (dashboardColumnsFor(constraints.crossAxisExtent) == 1) {
          return SliverList.separated(
            itemCount: keys.length + 1,
            itemBuilder: (context, i) => i == keys.length
                ? const WebAppsSection()
                : DashboardCardFrame(key: ValueKey(keys[i]), cardKey: keys[i]),
            separatorBuilder: (_, i) => SizedBox(height: i == keys.length - 1 ? _webAppsGap : 12),
            findItemIndexCallback: (key) {
              if (key is! ValueKey<String>) return null;
              final i = keys.indexOf(key.value);
              return i < 0 ? null : i;
            },
          );
        }
        return SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CardMasonry(
                children: [
                  for (final key in keys)
                    RepaintBoundary(
                      key: ValueKey(key),
                      child: DashboardCardFrame(cardKey: key),
                    ),
                ],
              ),
              const SizedBox(height: _webAppsGap),
              const RepaintBoundary(child: WebAppsSection()),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header();

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
    final updatedAt = ref.watch(dashboardProvider.select((s) => s.value?.generatedAt));
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
      children: [
        for (final h in [160.0, 120.0, 140.0, 120.0]) SkeletonBox(height: h, radius: 16),
      ],
    );
  }
}
