/// Small building blocks shared by the library screens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/links/external_links.dart';
import 'package:yams_hub/core/servers/server_config_provider.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/library_api.dart';
import '../providers/library_providers.dart';

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

/// Starts a command, shows "<label> started" and tracks it until it
/// finishes (result SnackBar from [LibraryCommandsController]).
Future<void> libraryRunCommand(
  BuildContext context,
  WidgetRef ref,
  Future<CommandRef> Function() start, {
  required String label,
  LibraryKind? kind,
  int? itemId,
}) async {
  try {
    final command = await start();
    ref.read(libraryCommandsProvider.notifier).track(command, label: label, kind: kind, itemId: itemId);
    if (context.mounted) context.showSnack('$label started');
  } catch (e) {
    if (context.mounted) context.showError(e);
  }
}

/// Progress chips of the commands running for one series/movie.
class LibraryCommandChips extends ConsumerWidget {
  const LibraryCommandChips({super.key, required this.kind, required this.itemId});

  final LibraryKind kind;
  final int itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(libraryCommandsProvider).where((c) => c.isFor(kind, itemId)).toList();
    if (running.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final c in running)
          Chip(
            avatar: const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            label: Text('${c.label} · ${c.ref.status == CommandStatus.started ? 'running' : 'queued'}'),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Chips and labels
// ---------------------------------------------------------------------------

/// Read-only tag chips.
class LibraryTagChips extends StatelessWidget {
  const LibraryTagChips(this.tags, {super.key});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final t in tags)
          Chip(
            avatar: const Icon(Icons.sell_outlined, size: 16),
            label: Text(t),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
      ],
    );
  }
}

/// `Continuing`, `Ended`, ...
String librarySeriesStatusLabel(LibrarySeriesStatus s) => switch (s) {
  LibrarySeriesStatus.continuing => 'Continuing',
  LibrarySeriesStatus.ended => 'Ended',
  LibrarySeriesStatus.upcoming => 'Upcoming',
  LibrarySeriesStatus.deleted => 'Deleted',
  LibrarySeriesStatus.unknown => 'Unknown',
};

String librarySeriesTypeLabel(LibrarySeriesType t) => switch (t) {
  LibrarySeriesType.standard => 'Standard',
  LibrarySeriesType.daily => 'Daily',
  LibrarySeriesType.anime => 'Anime',
  LibrarySeriesType.unknown => 'Unknown',
};

String libraryMovieStatusLabel(LibraryMovieStatus s) => switch (s) {
  LibraryMovieStatus.tba => 'TBA',
  LibraryMovieStatus.announced => 'Announced',
  LibraryMovieStatus.inCinemas => 'In cinemas',
  LibraryMovieStatus.released => 'Released',
  LibraryMovieStatus.deleted => 'Deleted',
  LibraryMovieStatus.unknown => 'Unknown',
};

String libraryAvailabilityLabel(LibraryMinimumAvailability a) => switch (a) {
  LibraryMinimumAvailability.tba => 'TBA',
  LibraryMinimumAvailability.announced => 'Announced',
  LibraryMinimumAvailability.inCinemas => 'In cinemas',
  LibraryMinimumAvailability.released => 'Released',
  LibraryMinimumAvailability.unknown => 'Unknown',
};

/// "1080p Bluray" style short quality for tile badges.
String libraryShortQuality(String quality) {
  final m = RegExp(r'^(.*?)-(\d{3,4}p)(.*)$').firstMatch(quality);
  if (m == null) return quality;
  return '${m[2]} ${m[1]}${m[3]}'.trim();
}

/// A local date for an instant, or the `Date` fallback.
String libraryAirDate(DateTime? utc, String? date) =>
    utc != null ? formatDate(utc) : (date == null ? 'TBA' : formatCalendarDate(date));

/// A monitored bookmark toggle (admins); a static icon otherwise.
class LibraryMonitorToggle extends StatelessWidget {
  const LibraryMonitorToggle({
    super.key,
    required this.monitored,
    required this.onChanged,
    this.enabled = true,
    this.size = 22,
  });

  final bool monitored;

  /// Null hides the button (members see the state only).
  final ValueChanged<bool>? onChanged;
  final bool enabled;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = monitored ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant;
    final icon = Icon(monitored ? Icons.bookmark : Icons.bookmark_border, color: color, size: size);
    if (onChanged == null) {
      return Tooltip(message: monitored ? 'Monitored' : 'Not monitored', child: icon);
    }
    return IconButton(
      tooltip: monitored ? 'Monitored · tap to unmonitor' : 'Not monitored · tap to monitor',
      icon: icon,
      onPressed: enabled ? () => onChanged!(!monitored) : null,
    );
  }
}

// ---------------------------------------------------------------------------
// Header strip and health sheet
// ---------------------------------------------------------------------------

/// "71 series · 892 missing · 2.8 TB · 4.0 TB free" per app, with a health
/// icon that opens the health messages.
class LibrarySummaryHeader extends ConsumerWidget {
  const LibrarySummaryHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(librarySummaryProvider);
    final theme = Theme.of(context);
    final s = summary.value;
    if (s == null) {
      if (summary.hasError) return const SizedBox.shrink();
      return const Padding(padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: SkeletonBox(height: 18));
    }
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          children: [
            if (s.sonarr.configured) LibrarySummaryLine(service: ArrService.sonarr, summary: s.sonarr),
            if (s.radarr.configured) LibrarySummaryLine(service: ArrService.radarr, summary: s.radarr),
          ],
        ),
      ),
    );
  }
}

/// One app of the header strip / dashboard card.
class LibrarySummaryLine extends StatelessWidget {
  const LibrarySummaryLine({super.key, required this.service, required this.summary, this.dense = false});

  final ArrService service;
  final ArrSummary summary;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final problems = summary.problems;
    final hasError = problems.any((h) => h.type == HealthMessageType.error);
    final noun = service == ArrService.sonarr ? 'series' : 'movies';
    final parts = [
      '${formatCount(summary.itemCount)} $noun',
      '${formatCount(summary.missing)} missing',
      formatBytes(summary.sizeOnDiskBytes),
      if (summary.freeBytes case final free?) '${formatBytes(free)} free',
    ];
    return Row(
      children: [
        Icon(
          service == ArrService.sonarr ? Icons.tv : Icons.movie_outlined,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            parts.join(' · '),
            style: dense ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (summary.queue.total > 0)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: StatusChip(
              label: '${summary.queue.total} queued',
              tone: summary.queue.errors
                  ? StatusTone.error
                  : (summary.queue.warnings ? StatusTone.warning : StatusTone.info),
              dense: true,
            ),
          ),
        if (problems.isNotEmpty)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '${problems.length} health ${problems.length == 1 ? 'warning' : 'warnings'}',
            icon: Icon(
              hasError ? Icons.error_outline : Icons.warning_amber_rounded,
              color: hasError ? colors.error : colors.warning,
              size: 20,
            ),
            onPressed: () => LibraryHealthSheet.show(context, service, problems),
          ),
      ],
    );
  }
}

/// Bottom sheet listing *arr health messages with their wiki links.
class LibraryHealthSheet extends ConsumerWidget {
  const LibraryHealthSheet({super.key, required this.service, required this.messages});

  final ArrService service;
  final List<HealthMessage> messages;

  static Future<void> show(BuildContext context, ArrService service, List<HealthMessage> messages) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => LibraryHealthSheet(service: service, messages: messages),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = StatusColors.of(context);
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('${service.serviceId.displayName} health', style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final m in messages)
            ListTile(
              leading: Icon(
                m.type == HealthMessageType.error ? Icons.error_outline : Icons.warning_amber_rounded,
                color: m.type == HealthMessageType.error ? colors.error : colors.warning,
              ),
              title: Text(m.message),
              subtitle: Text(m.source),
              trailing: m.wikiUrl == null ? null : const Icon(Icons.open_in_new, size: 18),
              onTap: m.wikiUrl == null
                  ? null
                  : () {
                      final uri = Uri.tryParse(m.wikiUrl!);
                      if (uri != null) launchExternalUri(uri);
                    },
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Files and history
// ---------------------------------------------------------------------------

/// `MediaFileInfo` as a bottom sheet (quality, size, codecs, languages).
class LibraryFileInfoSheet extends StatelessWidget {
  const LibraryFileInfoSheet({super.key, required this.file, this.title});

  final MediaFileInfo file;
  final String? title;

  static Future<void> show(BuildContext context, MediaFileInfo file, {String? title}) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => LibraryFileInfoSheet(file: file, title: title),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title ?? 'File', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            SelectableText(file.relativePath, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            LibraryFileInfoList(file: file),
          ],
        ),
      ),
    );
  }
}

/// The key/value lines of a [MediaFileInfo].
class LibraryFileInfoList extends StatelessWidget {
  const LibraryFileInfoList({super.key, required this.file});

  final MediaFileInfo file;

  @override
  Widget build(BuildContext context) {
    final channels = file.audioChannels;
    return KeyValueList(
      dense: true,
      entries: [
        KeyValue(
          'Quality',
          [
            file.quality.name,
            if (file.quality.revision case final r?) 'v$r',
            if (file.quality.isRepack) 'Repack',
          ].join(' '),
        ),
        KeyValue('Size', formatBytes(file.sizeBytes)),
        if (file.customFormats.isNotEmpty)
          KeyValue('Custom formats', '${file.customFormats.join(', ')} (${file.customFormatScore})')
        else
          KeyValue('Format score', '${file.customFormatScore}'),
        if (file.releaseGroup != null) KeyValue('Release group', file.releaseGroup),
        if (file.edition != null) KeyValue('Edition', file.edition),
        if (file.resolution != null) KeyValue('Resolution', file.resolution),
        if (file.videoCodec != null) KeyValue('Video', [file.videoCodec!, ?file.videoDynamicRange].join(' · ')),
        if (file.audioCodec != null)
          KeyValue('Audio', [file.audioCodec!, if (channels != null) channels.toString()].join(' ')),
        if (file.audioLanguages.isNotEmpty) KeyValue('Audio languages', file.audioLanguages.join(', ')),
        if (file.subtitleLanguages.isNotEmpty) KeyValue('Subtitles', file.subtitleLanguages.join(', ')),
        if (file.languages.isNotEmpty) KeyValue('Languages', file.languages.join(', ')),
        if (file.runTime != null) KeyValue('Runtime', file.runTime),
        if (file.dateAdded != null) KeyValue('Added', formatDateTime(file.dateAdded)),
        if (file.cutoffNotMet) const KeyValue('Cutoff', 'Not met – an upgrade may be grabbed'),
      ],
    );
  }
}

IconData _historyIcon(ArrHistoryType t) => switch (t) {
  ArrHistoryType.grabbed => Icons.download,
  ArrHistoryType.imported => Icons.check_circle_outline,
  ArrHistoryType.failed => Icons.error_outline,
  ArrHistoryType.deleted => Icons.delete_outline,
  ArrHistoryType.renamed => Icons.drive_file_rename_outline,
  ArrHistoryType.ignored => Icons.block,
  ArrHistoryType.unknown => Icons.history,
};

String _historyVerb(ArrHistoryType t) => switch (t) {
  ArrHistoryType.grabbed => 'Grabbed',
  ArrHistoryType.imported => 'Imported',
  ArrHistoryType.failed => 'Failed',
  ArrHistoryType.deleted => 'Deleted',
  ArrHistoryType.renamed => 'Renamed',
  ArrHistoryType.ignored => 'Ignored',
  ArrHistoryType.unknown => 'Event',
};

/// One *arr history event.
class LibraryHistoryTile extends StatelessWidget {
  const LibraryHistoryTile({super.key, required this.item});

  final ArrHistoryItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final color = switch (item.type) {
      ArrHistoryType.imported => colors.ok,
      ArrHistoryType.failed => colors.error,
      ArrHistoryType.deleted => colors.warning,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    final details = [
      _historyVerb(item.type),
      ?item.episode?.label,
      ?item.indexer,
      ?item.releaseGroup,
      if (item.sizeBytes case final s?) formatBytes(s),
      ?item.reason,
    ];
    return ListTile(
      leading: Icon(_historyIcon(item.type), color: color),
      title: Text(item.sourceTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(details.join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          StatusChip(label: item.quality.name, dense: true),
          const SizedBox(height: 2),
          Tooltip(
            message: formatDateTime(item.date),
            child: Text(formatRelative(item.date), style: theme.textTheme.labelSmall),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Delete flow (APP.md §2.4)
// ---------------------------------------------------------------------------

/// Asks how to delete [title] and deletes it. Returns true when deleted.
///
/// Without files: `ConfirmDialog` with an exclusion checkbox; with "Also
/// delete files" ticked, a red `TypedConfirmDialog` that requires typing the
/// title follows.
Future<bool> libraryDeleteFlow(
  BuildContext context,
  WidgetRef ref, {
  required LibraryKind kind,
  required int id,
  required String title,
  required int fileCount,
  required int sizeBytes,
}) async {
  final app = kind == LibraryKind.tv ? 'Sonarr' : 'Radarr';
  // The gateway refuses file deletion unless its policy allows it.
  var allowDeleteFiles = false;
  try {
    allowDeleteFiles = (await ref.read(serverConfigProvider.future)).policy.allowArrDeleteFiles;
  } catch (_) {
    allowDeleteFiles = false;
  }
  if (!context.mounted) return false;
  var deleteFiles = false;
  var addExclusion = false;
  final canDeleteFiles = allowDeleteFiles && fileCount > 0;
  final confirmed = await ConfirmDialog.show(
    context,
    title: 'Remove $title?',
    message: 'Remove $title from $app? Files stay on disk.',
    confirmLabel: 'Remove',
    destructive: true,
    content: StatefulBuilder(
      builder: (context, setState) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: addExclusion,
            onChanged: (v) => setState(() => addExclusion = v ?? false),
            title: const Text('Add to import exclusion list'),
            subtitle: const Text('Lists will not add it again'),
          ),
          if (canDeleteFiles)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: deleteFiles,
              onChanged: (v) => setState(() => deleteFiles = v ?? false),
              title: Text('Also delete ${fileCount == 1 ? '1 file' : '$fileCount files'} (${formatBytes(sizeBytes)})'),
              subtitle: const Text('Permanent: there is no recycle bin'),
            ),
        ],
      ),
    ),
  );
  if (!confirmed || !context.mounted) return false;
  if (deleteFiles) {
    final typed = await TypedConfirmDialog.show(
      context,
      expected: title,
      title: 'Delete files permanently',
      message:
          'Permanently delete ${fileCount == 1 ? '1 file' : '$fileCount files'} (${formatBytes(sizeBytes)})? '
          'There is no recycle bin.',
    );
    if (!typed || !context.mounted) return false;
  }
  try {
    await ref.read(libraryApiProvider).delete(kind, id, deleteFiles: deleteFiles, addExclusion: addExclusion);
  } catch (e) {
    if (context.mounted) context.showError(e);
    return false;
  }
  if (kind == LibraryKind.tv) {
    ref.invalidate(seriesListProvider);
  } else {
    ref.invalidate(moviesListProvider);
  }
  ref.invalidate(librarySummaryProvider);
  if (context.mounted) context.showSnack(deleteFiles ? '$title and its files deleted' : '$title removed from $app');
  return true;
}

/// Awaits a pull-to-refresh reload. A failure is not rethrown: the provider
/// keeps the old data with its error, which the screen shows as a stale
/// banner (APP.md §2.1).
Future<void> libraryAwaitRefresh(Future<Object?> reload) async {
  try {
    await reload;
  } catch (_) {
    // Shown by the screen through the provider's error state.
  }
}

/// True for errors that mean "the item is gone" (detail screens show an
/// empty state instead of an error).
bool libraryIsNotFound(Object? error) => error != null && ApiException.from(error).code == ApiErrorCode.notFound;
