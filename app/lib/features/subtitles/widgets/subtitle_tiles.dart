/// Rows of the Episodes, Movies and History tabs (APP.md §11).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/subtitles_providers.dart';

/// "English", "English · Forced", "English · HI".
String subtitleLanguageLabel(SubtitleLanguage l) =>
    [l.name.isEmpty ? l.code : l.name, if (l.forced) 'Forced', if (l.hi) 'HI'].join(' · ');

/// One missing language. Admins tap it to search that language; the chip
/// shows a spinner while the search runs.
class SubtitleLanguageChip extends ConsumerWidget {
  const SubtitleLanguageChip({super.key, required this.item, required this.language});

  final WantedSubtitle item;
  final SubtitleLanguage language;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = Text(subtitleLanguageLabel(language));
    if (!ref.watch(isAdminProvider)) {
      return Chip(label: label, visualDensity: VisualDensity.compact);
    }
    final key = SubtitleSearchController.languageKey(item, language);
    final searching = ref.watch(subtitleSearchProvider.select((s) => s.isSearching(key)));
    return ActionChip(
      key: ValueKey('subtitle-chip-$key'),
      visualDensity: VisualDensity.compact,
      tooltip: searching ? 'Searching…' : 'Search ${subtitleLanguageLabel(language)} subtitles',
      avatar: searching
          ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.search, size: 16),
      label: label,
      onPressed: searching
          ? null
          : () async {
              try {
                await ref.read(subtitleSearchProvider.notifier).searchLanguage(item, language);
                if (context.mounted) context.showSnack('Search started');
              } catch (e) {
                if (context.mounted) context.showError(e);
              }
            },
    );
  }
}

/// A wanted episode or movie: poster, title, episode label + title and the
/// missing language chips. Tapping opens the item in the library.
class WantedSubtitleTile extends ConsumerWidget {
  const WantedSubtitleTile({super.key, required this.item});

  final WantedSubtitle item;

  String? get _libraryRoute => switch (item.type) {
    SubtitleMediaType.episode when item.seriesId != null => AppPaths.seriesDetail(item.seriesId!),
    SubtitleMediaType.movie when item.movieId != null => AppPaths.movieDetail(item.movieId!),
    _ => null,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isAdmin = ref.watch(isAdminProvider);
    final isMovie = item.type == SubtitleMediaType.movie;
    final episode = [?item.episodeLabel, ?item.episodeTitle].join(' · ');
    final route = _libraryRoute;
    return InkWell(
      onTap: route == null ? null : () => context.go(route),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HubImage(
              item.posterPath,
              width: 48,
              height: 72,
              borderRadius: BorderRadius.circular(6),
              placeholderIcon: isMovie ? Icons.movie_outlined : Icons.tv_outlined,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title, style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (episode.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        episode,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [for (final l in item.missing) SubtitleLanguageChip(item: item, language: l)],
                  ),
                ],
              ),
            ),
            if (isAdmin && (isMovie ? item.movieId : item.seriesId) != null)
              _ItemMenu(item: item)
            else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

class _ItemMenu extends ConsumerWidget {
  const _ItemMenu({required this.item});

  final WantedSubtitle item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = SubtitleSearchController.itemKey(item);
    final searching = ref.watch(subtitleSearchProvider.select((s) => s.isSearching(key)));
    if (searching) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final label = item.type == SubtitleMediaType.movie ? 'Search all for this movie' : 'Search all for this series';
    return PopupMenuButton<void>(
      key: ValueKey('subtitle-item-menu-${item.key}'),
      tooltip: 'Search options',
      itemBuilder: (_) => [
        PopupMenuItem<void>(
          onTap: () async {
            try {
              await ref.read(subtitleSearchProvider.notifier).searchItem(item);
              if (context.mounted) context.showSnack('Search started');
            } catch (e) {
              if (context.mounted) context.showError(e);
            }
          },
          child: ListTile(
            leading: const Icon(Icons.manage_search),
            title: Text(label),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}

/// Icon of a history action.
IconData subtitleHistoryIcon(SubtitleHistoryAction a) => switch (a) {
  SubtitleHistoryAction.downloaded => Icons.download_outlined,
  SubtitleHistoryAction.upgraded => Icons.upgrade,
  SubtitleHistoryAction.manual => Icons.touch_app_outlined,
  SubtitleHistoryAction.uploaded => Icons.upload_outlined,
  SubtitleHistoryAction.deleted => Icons.delete_outline,
  SubtitleHistoryAction.synced => Icons.sync,
  SubtitleHistoryAction.translated => Icons.translate,
  SubtitleHistoryAction.extracted => Icons.content_cut,
  SubtitleHistoryAction.unknown => Icons.history,
};

/// Label of a history action.
String subtitleHistoryLabel(SubtitleHistoryAction a) => switch (a) {
  SubtitleHistoryAction.downloaded => 'Downloaded',
  SubtitleHistoryAction.upgraded => 'Upgraded',
  SubtitleHistoryAction.manual => 'Manual',
  SubtitleHistoryAction.uploaded => 'Uploaded',
  SubtitleHistoryAction.deleted => 'Deleted',
  SubtitleHistoryAction.synced => 'Synced',
  SubtitleHistoryAction.translated => 'Translated',
  SubtitleHistoryAction.extracted => 'Extracted',
  SubtitleHistoryAction.unknown => 'Other',
};

/// A history entry: action icon, title, language, provider, score, time and
/// description.
class SubtitleHistoryTile extends StatelessWidget {
  const SubtitleHistoryTile({super.key, required this.item});

  final SubtitleHistoryItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final title = [item.title, ?item.episodeLabel].join(' · ');
    final facts = [
      subtitleHistoryLabel(item.action),
      if (item.language case final l?) subtitleLanguageLabel(l),
      ?item.provider,
      ?item.score,
    ].join(' · ');
    final tone = switch (item.action) {
      SubtitleHistoryAction.deleted => StatusTone.error,
      SubtitleHistoryAction.downloaded || SubtitleHistoryAction.upgraded => StatusTone.ok,
      _ => StatusTone.info,
    };
    final color = StatusColors.of(context).forTone(tone);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.16),
        foregroundColor: color,
        child: Icon(subtitleHistoryIcon(item.action), size: 20),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(facts, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (item.description case final d?) Text(d, style: muted, maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
      isThreeLine: item.description != null,
      trailing: item.at == null
          ? null
          : Tooltip(
              message: formatDateTime(item.at),
              triggerMode: TooltipTriggerMode.longPress,
              child: Text(formatRelative(item.at), style: muted),
            ),
    );
  }
}
