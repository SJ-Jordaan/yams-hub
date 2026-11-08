// The `media` dashboard card ("Now playing", APP.md §3.3). Core's
// DashboardCardFrame supplies the title, route and error/disabled/stale
// states; this widget renders `section.data` when the section is ok.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/dashboard/section_decode.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import 'screens/media_screen.dart';
import 'widgets/session_card.dart';

/// The `media` card on the dashboard (API.md §4, §14.8).
class MediaDashboardCard extends ConsumerWidget {
  const MediaDashboardCard({super.key, required this.section});

  final Section section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final MediaCard? card;
    try {
      card = decodeCached(section, MediaCard.fromJson);
    } on FormatException {
      return Text('The hub sent data this app does not understand.', style: theme.textTheme.bodyMedium);
    }
    if (card == null) return const SizedBox.shrink();
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final counts = card.counts;
    final extras = _extras(card);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (card.nowPlaying.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(Icons.tv_off_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text('Nothing playing', style: theme.textTheme.bodyMedium),
              ],
            ),
          )
        else ...[
          if (card.transcoding > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${card.nowPlaying.length} playing · ${card.transcoding} transcoding',
                style: theme.textTheme.labelMedium,
              ),
            ),
          for (final s in card.nowPlaying)
            SessionRow(
              key: ValueKey(s.id),
              session: s,
              onTap: () => context.go(AppPaths.media(tab: MediaTab.playing.name)),
            ),
        ],
        if (counts != null)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => context.go(AppPaths.mediaJellyfin()),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.video_library_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${formatCount(counts.movies)} movies · ${formatCount(counts.series)} shows · '
                      '${formatCount(counts.episodes)} episodes',
                      style: muted,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (extras.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final e in extras)
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(
                    e.icon,
                    size: 16,
                    color: e.tone == null ? null : StatusColors.of(context).forTone(e.tone!),
                  ),
                  label: Text(e.label),
                  onPressed: () => context.go(e.route),
                ),
            ],
          ),
      ],
    );
  }

  static List<({IconData icon, String label, String route, StatusTone? tone})> _extras(MediaCard card) {
    final out = <({IconData icon, String label, String route, StatusTone? tone})>[];
    final abs = card.audiobooks;
    if (abs != null) {
      out.add((
        icon: Icons.headphones,
        label: abs.inProgress > 0
            ? '${formatCount(abs.items)} audiobooks · ${abs.inProgress} in progress'
            : '${formatCount(abs.items)} audiobooks',
        route: AppPaths.mediaAudiobooks(),
        tone: null,
      ));
    }
    final books = card.books;
    if (books != null) {
      final needsKey = books.auth == BooksAuth.missingKey || books.auth == BooksAuth.rejected;
      out.add((
        icon: needsKey ? Icons.key_outlined : Icons.menu_book,
        label: needsKey ? 'Kavita needs a key' : '${formatCount(books.series)} book series',
        route: AppPaths.mediaBooks(),
        tone: needsKey ? StatusTone.warning : null,
      ));
    }
    final sm = card.shelfmark;
    if (sm != null && (sm.active > 0 || sm.queued > 0 || sm.failed7d > 0)) {
      out.add((
        icon: sm.failed7d > 0 ? Icons.error_outline : Icons.downloading,
        label: [
          if (sm.active > 0) '${sm.active} downloading',
          if (sm.queued > 0) '${sm.queued} queued',
          if (sm.failed7d > 0) '${sm.failed7d} failed',
        ].join(' · '),
        route: AppPaths.mediaShelfmark(),
        tone: sm.failed7d > 0 ? StatusTone.error : null,
      ));
    }
    return out;
  }
}
