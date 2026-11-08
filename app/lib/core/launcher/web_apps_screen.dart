/// `/home/apps`: the Homepage-replacement launcher (APP.md §3.5).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../links/external_links.dart';
import '../servers/server_config_provider.dart';
import '../widgets/async_value_view.dart';
import '../widgets/skeleton.dart';
import '../widgets/snack.dart';
import '../widgets/web_app_tile.dart';
import 'launcher_providers.dart';

class WebAppsScreen extends ConsumerWidget {
  const WebAppsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(launcherEntriesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Web apps')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(healthProvider);
          ref.invalidate(serverConfigProvider);
          await ref.read(launcherEntriesProvider.future);
        },
        child: AsyncValueView(
          value: entries,
          onRetry: () => ref.invalidate(serverConfigProvider),
          loading: const SkeletonPosterGrid(count: 8, maxTileWidth: 160),
          data: (context, list) => _LauncherGrid(entries: list),
        ),
      ),
    );
  }
}

class _LauncherGrid extends StatelessWidget {
  const _LauncherGrid({required this.entries});

  final List<LauncherEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (entries.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          Padding(
            padding: EdgeInsets.all(32),
            child: Text('All apps are hidden. Show them again in Settings > Appearance.', textAlign: TextAlign.center),
          ),
        ],
      );
    }
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        for (final group in LauncherGroup.values)
          if (entries.any((e) => e.group == group)) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              sliver: SliverToBoxAdapter(child: Text(group.label, style: theme.textTheme.titleSmall)),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid.extent(
                maxCrossAxisExtent: 160,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.9,
                children: [
                  for (final e in entries.where((e) => e.group == group)) LauncherTile(entry: e),
                ],
              ),
            ),
          ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

/// A [WebAppTile] for a [LauncherEntry]: tap opens the web UI (a new tab on
/// web), long-press offers "Copy link".
class LauncherTile extends ConsumerWidget {
  const LauncherTile({super.key, required this.entry, this.compact = false});

  final LauncherEntry entry;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return WebAppTile(
      icon: entry.icon,
      name: entry.name,
      status: entry.status,
      version: entry.version,
      compact: compact,
      onTap: () async {
        final url = entry.url;
        final ok = url != null && await launchExternalUri(url);
        if (!ok && context.mounted) context.showSnack("Couldn't open ${entry.name}");
      },
      onLongPress: () => _copyLink(context),
    );
  }

  Future<void> _copyLink(BuildContext context) async {
    final url = entry.url;
    if (url == null) return;
    final copy = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(entry.name), subtitle: Text(url.toString())),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy link'),
              onTap: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ),
    );
    if (copy != true) return;
    await Clipboard.setData(ClipboardData(text: url.toString()));
    if (context.mounted) context.showSnack('Link copied');
  }
}
