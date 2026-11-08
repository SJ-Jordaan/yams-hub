/// Small shared pieces of the media screens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/links/external_links.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

/// `43:05` or `1:02:03`.
String formatClock(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}

/// `12h 30m`, `45m`, `0m` (watch and listening time).
String formatWatchTime(int seconds) {
  if (seconds <= 0) return '0m';
  final d = Duration(seconds: seconds);
  if (d.inHours >= 48) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes >= 1) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}

/// "Direct play", "Direct stream", "Transcode · QSV".
String playMethodLabel(MediaPlayMethod method, {String? hwAccel}) {
  if (method == MediaPlayMethod.transcode) {
    return hwAccel == null ? 'Transcode' : 'Transcode · ${hwAccel.toUpperCase()}';
  }
  return method.label;
}

StatusTone playMethodTone(MediaPlayMethod method) => switch (method) {
  MediaPlayMethod.directPlay => StatusTone.ok,
  MediaPlayMethod.directStream => StatusTone.info,
  MediaPlayMethod.transcode => StatusTone.warning,
  MediaPlayMethod.unknown => StatusTone.neutral,
};

/// The coloured play-method chip of a session.
class PlayMethodChip extends StatelessWidget {
  const PlayMethodChip({super.key, required this.method, this.hwAccel, this.dense = true});

  final MediaPlayMethod method;
  final String? hwAccel;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return StatusChip(
      label: playMethodLabel(method, hwAccel: hwAccel),
      tone: playMethodTone(method),
      icon: method == MediaPlayMethod.transcode ? Icons.memory : null,
      dense: dense,
    );
  }
}

/// Opens [link] and reports a failure in a SnackBar.
Future<void> openLink(BuildContext context, WidgetRef ref, ExternalLink? link, {String name = 'the app'}) async {
  final ok = link != null && await openExternal(ref, link);
  if (!ok && context.mounted) context.showSnack("Couldn't open $name");
}

/// A titled section of a scrolling detail screen.
class MediaSection extends StatelessWidget {
  const MediaSection({super.key, required this.title, required this.child, this.trailing, this.padding});

  final String title;
  final Widget child;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
                ?trailing,
              ],
            ),
          ),
          Padding(padding: padding ?? const EdgeInsets.symmetric(horizontal: 16), child: child),
        ],
      ),
    );
  }
}

/// A big number with a label (stats rows).
class MediaStatTile extends StatelessWidget {
  const MediaStatTile({super.key, required this.label, required this.value, this.icon, this.tone, this.onTap});

  final String label;
  final String value;
  final IconData? icon;
  final StatusTone? tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tone == null ? theme.colorScheme.primary : StatusColors.of(context).forTone(tone!);
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (icon != null) ...[Icon(icon, size: 16, color: color), const SizedBox(width: 6)],
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleLarge),
            ],
          ),
        ),
      ),
    );
  }
}

/// A wrap of [MediaStatTile]s that fills the width (2 per row on phones).
class MediaStatGrid extends StatelessWidget {
  const MediaStatGrid({super.key, required this.children, this.minTileWidth = 150});

  final List<Widget> children;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        const spacing = 8.0;
        final columns = ((c.maxWidth + spacing) / (minTileWidth + spacing)).floor().clamp(1, 6);
        final width = (c.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [for (final child in children) SizedBox(width: width, child: child)],
        );
      },
    );
  }
}

/// A horizontal row of 2:3 posters.
class MediaPosterRow extends StatelessWidget {
  const MediaPosterRow({super.key, required this.children, this.tileWidth = 112, this.height = 256});

  final List<Widget> children;
  final double tileWidth;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: children.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) => SizedBox(width: tileWidth, child: children[i]),
      ),
    );
  }
}

/// A wrapping grid of 2:3 posters (3 per row on phones, more when wider).
class MediaPosterGrid extends StatelessWidget {
  const MediaPosterGrid({super.key, required this.children, this.minTileWidth = 104});

  final List<Widget> children;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        const spacing = 12.0;
        final columns = ((c.maxWidth + spacing) / (minTileWidth + spacing)).floor().clamp(2, 8);
        final width = (c.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: 16,
          children: [for (final child in children) SizedBox(width: width, child: child)],
        );
      },
    );
  }
}

/// A [PosterTile] for a Jellyfin [MediaItem]; tap opens it in Jellyfin.
class MediaItemPoster extends ConsumerWidget {
  const MediaItemPoster({super.key, required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = item.newEpisodeCount;
    final progress = item.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PosterTile(
          imagePath: item.imagePath,
          title: item.title,
          subtitle: item.subtitle ?? item.year?.toString(),
          placeholderIcon: item.type == MediaItemType.movie ? Icons.movie_outlined : Icons.tv_outlined,
          badge: count == null ? null : _CountBadge(count: count),
          onTap: () => openLink(context, ref, item.jellyfin, name: 'Jellyfin'),
        ),
        if (progress != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ProgressBar(value: progress, height: 3),
          ),
      ],
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '$count unplayed',
      child: DecoratedBox(
        decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(10)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          child: Text(
            count > 99 ? '99+' : '$count',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onPrimary),
          ),
        ),
      ),
    );
  }
}

/// A horizontal skeleton of posters (first load of a poster row).
class SkeletonPosterRow extends StatelessWidget {
  const SkeletonPosterRow({super.key, this.count = 6});

  final int count;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 256,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: count,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, _) => const SkeletonBox(width: 112, height: 168, radius: 12),
      ),
    );
  }
}

/// A full-screen detail skeleton: stat tiles and two poster rows.
class MediaDetailSkeleton extends StatelessWidget {
  const MediaDetailSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: const [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(child: SkeletonBox(height: 64)),
              SizedBox(width: 8),
              Expanded(child: SkeletonBox(height: 64)),
            ],
          ),
        ),
        SizedBox(height: 24),
        SkeletonPosterRow(),
        SizedBox(height: 24),
        SkeletonPosterRow(),
      ],
    );
  }
}

/// A scrollable body that always supports pull-to-refresh.
class MediaRefreshList extends StatelessWidget {
  const MediaRefreshList({super.key, required this.onRefresh, required this.children});

  final Future<void> Function() onRefresh;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 32),
        children: children,
      ),
    );
  }
}

/// A coloured warning/info banner card.
class MediaNoticeCard extends StatelessWidget {
  const MediaNoticeCard({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.tone = StatusTone.warning,
    this.action,
    this.onDismiss,
  });

  final IconData icon;
  final String title;
  final String? message;
  final StatusTone tone;
  final Widget? action;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = StatusColors.of(context).forTone(tone);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      color: color.withValues(alpha: 0.14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  if (message != null) ...[
                    const SizedBox(height: 4),
                    Text(message!, style: theme.textTheme.bodyMedium),
                  ],
                  if (action != null) ...[const SizedBox(height: 8), action!],
                ],
              ),
            ),
            if (onDismiss != null)
              IconButton(
                tooltip: 'Dismiss',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close),
                onPressed: onDismiss,
              ),
          ],
        ),
      ),
    );
  }
}
