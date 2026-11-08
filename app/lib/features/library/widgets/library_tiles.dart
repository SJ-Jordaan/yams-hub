/// Poster tiles and list rows of the TV and Movies tabs (APP.md §5.1).
library;

import 'package:flutter/material.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import 'library_widgets.dart';

/// A 2:3 poster with corner badges, a bottom progress bar and an optional
/// "unmonitored" dimming.
class LibraryPosterCard extends StatelessWidget {
  const LibraryPosterCard({
    super.key,
    required this.imagePath,
    required this.title,
    this.subtitle,
    this.progress,
    this.topLeft,
    this.topRight,
    this.dimmed = false,
    this.placeholderIcon = Icons.tv,
    this.onTap,
  });

  final String? imagePath;
  final String title;
  final String? subtitle;

  /// 0..1; null hides the bar.
  final double? progress;
  final Widget? topLeft;
  final Widget? topRight;
  final bool dimmed;
  final IconData placeholderIcon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final p = progress;
    return Semantics(
      button: onTap != null,
      label: title,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    LayoutBuilder(
                      builder: (context, c) => HubImage(
                        imagePath,
                        width: c.maxWidth,
                        height: c.maxHeight,
                        placeholderIcon: placeholderIcon,
                        opacity: dimmed ? 0.45 : 1,
                      ),
                    ),
                    if (dimmed)
                      Positioned(
                        left: 6,
                        bottom: p == null ? 6 : 12,
                        child: Icon(Icons.bookmark_remove_outlined, size: 20, color: theme.colorScheme.onSurface),
                      ),
                    if (topLeft != null) Positioned(top: 6, left: 6, child: topLeft!),
                    if (topRight != null) Positioned(top: 6, right: 6, child: topRight!),
                    if (p != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          value: p.clamp(0, 1),
                          minHeight: 4,
                          backgroundColor: Colors.black45,
                          color: p >= 1 ? colors.ok : theme.colorScheme.primary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
            if (subtitle != null)
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

/// A small solid badge on a poster.
class LibraryBadge extends StatelessWidget {
  const LibraryBadge(this.label, {super.key, this.tone = StatusTone.neutral, this.icon});

  final String label;
  final StatusTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    final bg = switch (tone) {
      StatusTone.ok => colors.ok,
      StatusTone.warning => colors.warning,
      StatusTone.error => colors.error,
      StatusTone.info => colors.info,
      StatusTone.neutral => Colors.black87,
    };
    final fg = tone == StatusTone.neutral ? Colors.white : colors.onStatus;
    return DecoratedBox(
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 12, color: fg), const SizedBox(width: 2)],
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}

/// Grid tile of a series.
class SeriesGridTile extends StatelessWidget {
  const SeriesGridTile({super.key, required this.series, this.onTap});

  final SeriesSummary series;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = series;
    return LibraryPosterCard(
      imagePath: s.posterPath,
      title: s.title,
      subtitle: [?s.year?.toString(), '${s.episodeFileCount}/${s.episodeCount}'].join(' · '),
      progress: s.episodeCount == 0 ? null : s.percentComplete / 100,
      dimmed: !s.monitored,
      topLeft: s.isAnime ? const LibraryBadge('A', tone: StatusTone.info) : null,
      topRight: s.missingCount > 0 ? LibraryBadge('${s.missingCount}', tone: StatusTone.error) : null,
      onTap: onTap,
    );
  }
}

/// List row of a series.
class SeriesListRow extends StatelessWidget {
  const SeriesListRow({super.key, required this.series, this.onTap});

  final SeriesSummary series;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = series;
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final meta = [?s.network, ?s.year?.toString(), librarySeriesStatusLabel(s.status)].join(' · ');
    final next = s.nextAiring;
    return ListTile(
      onTap: onTap,
      leading: SizedBox(
        width: 40,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: HubImage(
            s.posterPath,
            width: 40,
            height: 60,
            borderRadius: BorderRadius.circular(6),
            opacity: s.monitored ? 1 : 0.45,
          ),
        ),
      ),
      title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [meta, if (next != null) 'Next ${formatDate(next)}'].join('\n'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: next != null,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '${s.episodeFileCount}/${s.episodeCount}',
            style: theme.textTheme.labelLarge?.copyWith(color: s.missingCount > 0 ? colors.error : null),
          ),
          Text(formatBytes(s.sizeOnDiskBytes), style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

/// Grid tile of a movie.
class MovieGridTile extends StatelessWidget {
  const MovieGridTile({super.key, required this.movie, this.onTap});

  final MovieSummary movie;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final m = movie;
    final Widget? badge;
    if (m.hasFile && m.quality != null) {
      badge = LibraryBadge(
        libraryShortQuality(m.quality!),
        tone: m.cutoffNotMet ? StatusTone.warning : StatusTone.neutral,
      );
    } else if (!m.isAvailable) {
      badge = const LibraryBadge('Not released');
    } else if (!m.hasFile && m.monitored) {
      badge = const LibraryBadge('Missing', tone: StatusTone.error);
    } else {
      badge = null;
    }
    return LibraryPosterCard(
      imagePath: m.posterPath,
      title: m.title,
      subtitle: [?m.year?.toString(), if (m.runtimeMinutes case final r?) '${r}m'].join(' · '),
      dimmed: !m.monitored,
      placeholderIcon: Icons.movie_outlined,
      topRight: badge,
      onTap: onTap,
    );
  }
}

/// List row of a movie.
class MovieListRow extends StatelessWidget {
  const MovieListRow({super.key, required this.movie, this.onTap});

  final MovieSummary movie;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final m = movie;
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final status = m.hasFile
        ? (m.quality ?? 'Downloaded')
        : (!m.isAvailable ? 'Not released' : (m.monitored ? 'Missing' : 'Not monitored'));
    return ListTile(
      onTap: onTap,
      leading: SizedBox(
        width: 40,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: HubImage(
            m.posterPath,
            width: 40,
            height: 60,
            borderRadius: BorderRadius.circular(6),
            placeholderIcon: Icons.movie_outlined,
            opacity: m.monitored ? 1 : 0.45,
          ),
        ),
      ),
      title: Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [?m.year?.toString(), ?m.studio, libraryMovieStatusLabel(m.status)].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            status,
            style: theme.textTheme.labelLarge?.copyWith(
              color: !m.hasFile && m.isAvailable && m.monitored ? colors.error : null,
            ),
          ),
          if (m.hasFile) Text(formatBytes(m.sizeOnDiskBytes), style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}
