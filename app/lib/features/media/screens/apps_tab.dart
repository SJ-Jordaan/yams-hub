/// Media > Apps (APP.md §8.3): rich tiles for the media apps, refreshed
/// every 60 s.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/launcher/launcher_providers.dart';
import 'package:yams_hub/core/links/external_links.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/media_providers.dart';

ServiceHealthStatus _health(MediaAppStatus s) => switch (s) {
  MediaAppStatus.up => ServiceHealthStatus.up,
  MediaAppStatus.degraded => ServiceHealthStatus.degraded,
  MediaAppStatus.down => ServiceHealthStatus.down,
  MediaAppStatus.disabled => ServiceHealthStatus.disabled,
  MediaAppStatus.unknown => ServiceHealthStatus.unknown,
};

class AppsTab extends ConsumerWidget {
  const AppsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(mediaAppsProvider);
    return AsyncValueView<List<MediaApp>>(
      value: value,
      onRetry: () => ref.invalidate(mediaAppsProvider),
      loading: const SkeletonList(count: 5, leadingSize: 48),
      data: (context, apps) => RefreshIndicator(
        onRefresh: () => ref.refresh(mediaAppsProvider.future),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 420,
                  mainAxisExtent: 172,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
                delegate: SliverChildListDelegate([for (final a in apps) MediaAppTile(app: a)]),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => context.go(AppPaths.webApps()),
                    icon: const Icon(Icons.apps),
                    label: const Text('All web apps'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One large tile: icon, name, status, version, headline and the two open
/// buttons; the body opens the app's detail route.
class MediaAppTile extends ConsumerWidget {
  const MediaAppTile({super.key, required this.app});

  final MediaApp app;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final external = app.app.externalApp;
    final icon = launcherApps[external]?.icon ?? Icons.apps;
    final health = _health(app.status);
    final webOnly = app.app == MediaAppKind.shelfmark;

    Future<void> open(Future<bool> Function() launch) async {
      final ok = await launch();
      if (!ok && context.mounted) context.showSnack("Couldn't open ${app.name}");
    }

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: app.route.isEmpty ? null : () => context.go(app.route),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: scheme.primaryContainer,
                    child: Icon(icon, color: scheme.onPrimaryContainer),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(app.name, style: theme.textTheme.titleMedium),
                        Row(
                          children: [
                            StatusDot(tone: toneForHealth(health), tooltip: WebAppTile.statusLabel(health)),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                [
                                  WebAppTile.statusLabel(health),
                                  if (app.version != null) 'v${app.version}',
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Text(
                  app.headline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              Row(
                children: [
                  if (!webOnly) ...[
                    Flexible(
                      child: FilledButton.tonalIcon(
                        onPressed: () => open(() => openApp(ref, external)),
                        icon: const Icon(Icons.launch, size: 18),
                        label: const Text('Open app', maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: TextButton.icon(
                      onPressed: () => open(() => openExternal(ref, app.web)),
                      icon: const Icon(Icons.public, size: 18),
                      label: const Text('Open web', maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
