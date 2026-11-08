/// Maps Bazarr 1.6 bodies to the subtitles DTOs (API.md §12,
/// integrations/downloads.md §4).
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

/// Bazarr history action codes (frontend bundle): 0 delete, 1 download,
/// 2 manual, 3 upgrade, 4 upload, 5 sync, 6 translated, 7 extracted.
const _historyActions = [
  SubtitleHistoryAction.deleted,
  SubtitleHistoryAction.downloaded,
  SubtitleHistoryAction.manual,
  SubtitleHistoryAction.upgraded,
  SubtitleHistoryAction.uploaded,
  SubtitleHistoryAction.synced,
  SubtitleHistoryAction.translated,
  SubtitleHistoryAction.extracted,
];

final _episodeNumber = RegExp(r'^\s*(\d+)\s*x\s*(\d+)\s*$');

/// `MM/dd/yy HH:mm:ss`, in UTC (Bazarr's timezone is `Etc/UTC`).
final _parsedTimestamp = RegExp(
  r'^(\d{1,2})/(\d{1,2})/(\d{2}) (\d{1,2}):(\d{2}):(\d{2})$',
);

/// Pure mapping from Bazarr JSON to the hub DTOs.
final class BazarrMapper {
  BazarrMapper({required this.images, required this.redact});

  final ImageUrls images;

  /// `redactSecrets` for upstream-derived texts.
  final String Function(String) redact;

  /// `"1x11"` → `"S01E11"`; other shapes are passed through unchanged.
  static String? episodeLabel(Object? episodeNumber) {
    final raw = readString(episodeNumber);
    if (raw == null || raw.trim().isEmpty) return null;
    final m = _episodeNumber.firstMatch(raw);
    if (m == null) return raw.trim();
    return ArrEpisodeLabel.format(int.parse(m[1]!), int.parse(m[2]!));
  }

  /// Bazarr's `parsed_timestamp` (`11/08/26 07:53:14`, UTC); null when
  /// absent or malformed.
  static DateTime? parsedTimestamp(Object? v) {
    final s = readString(v)?.trim();
    if (s == null) return null;
    final m = _parsedTimestamp.firstMatch(s);
    if (m == null) return null;
    int g(int i) => int.parse(m[i]!);
    final month = g(1), day = g(2), year = g(3);
    final hour = g(4), minute = g(5), second = g(6);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    if (hour > 23 || minute > 59 || second > 59) return null;
    return DateTime.utc(2000 + year, month, day, hour, minute, second);
  }

  /// A history action code; unknown codes map to `unknown`.
  static SubtitleHistoryAction historyAction(Object? code) {
    final i = readInt(code);
    if (i == null || i < 0 || i >= _historyActions.length) {
      return SubtitleHistoryAction.unknown;
    }
    return _historyActions[i];
  }

  /// `{name, code2, code3, forced, hi}` → [SubtitleLanguage]; null without a
  /// code.
  static SubtitleLanguage? language(Object? v) {
    final j = readMap(v);
    if (j == null) return null;
    final code = readString(j['code2']) ?? readString(j['code3']);
    if (code == null || code.isEmpty) return null;
    return SubtitleLanguage(
      code: code,
      name: readString(j['name']) ?? code,
      forced: readBool(j['forced']) ?? false,
      hi: readBool(j['hi']) ?? false,
    );
  }

  static List<SubtitleLanguage> _languages(Object? v) => [
    if (v is List)
      for (final l in v) ?language(l),
  ];

  String? _text(Object? v) {
    final s = readString(v)?.trim();
    return (s == null || s.isEmpty) ? null : redact(s);
  }

  /// An item of `GET /api/episodes/wanted`.
  WantedSubtitle wantedEpisode(JsonMap j) {
    final seriesId = readInt(j['sonarrSeriesId']);
    return WantedSubtitle(
      type: SubtitleMediaType.episode,
      title: readString(j['seriesTitle']) ?? '',
      episodeLabel: episodeLabel(j['episode_number']),
      episodeTitle: _text(j['episodeTitle']),
      seriesId: seriesId,
      episodeId: readInt(j['sonarrEpisodeId']),
      missing: _languages(j['missing_subtitles']),
      posterPath: seriesId == null
          ? null
          : images.arr(ArrService.sonarr, seriesId, 'poster', size: 250),
      seriesType: readString(j['seriesType']),
    );
  }

  /// An item of `GET /api/movies/wanted`.
  WantedSubtitle wantedMovie(JsonMap j) {
    final movieId = readInt(j['radarrId']);
    return WantedSubtitle(
      type: SubtitleMediaType.movie,
      title: readString(j['title']) ?? '',
      movieId: movieId,
      missing: _languages(j['missing_subtitles']),
      posterPath: movieId == null
          ? null
          : images.arr(ArrService.radarr, movieId, 'poster', size: 250),
    );
  }

  /// A record of `GET /api/episodes/history`.
  SubtitleHistoryItem historyEpisode(JsonMap j) => SubtitleHistoryItem(
    type: SubtitleMediaType.episode,
    title: readString(j['seriesTitle']) ?? '',
    episodeLabel: episodeLabel(j['episode_number']),
    action: historyAction(j['action']),
    language: language(j['language']),
    provider: _text(j['provider']),
    score: _text(j['score']),
    description: _text(j['description']),
    at: parsedTimestamp(j['parsed_timestamp']),
  );

  /// A record of `GET /api/movies/history`.
  SubtitleHistoryItem historyMovie(JsonMap j) => SubtitleHistoryItem(
    type: SubtitleMediaType.movie,
    title: readString(j['title']) ?? '',
    action: historyAction(j['action']),
    language: language(j['language']),
    provider: _text(j['provider']),
    score: _text(j['score']),
    description: _text(j['description']),
    at: parsedTimestamp(j['parsed_timestamp']),
  );

  /// An entry of `GET /api/providers`. A provider is ok when its status is
  /// `Good`; `retry` `-` means none.
  SubtitleProvider provider(JsonMap j) {
    final status = readString(j['status'])?.trim() ?? '';
    final retry = readString(j['retry'])?.trim();
    return SubtitleProvider(
      name: readString(j['name']) ?? '',
      status: redact(status),
      retry: (retry == null || retry.isEmpty || retry == '-')
          ? null
          : redact(retry),
      ok: status == 'Good',
    );
  }

  /// An item of `GET /api/system/health`.
  SubtitleHealthIssue healthIssue(JsonMap j) => SubtitleHealthIssue(
    object: _text(j['object']) ?? '',
    issue: _text(j['issue']) ?? '',
  );

  /// An item of `GET /api/system/tasks`.
  static SubtitleTask? task(JsonMap j) {
    final id = readString(j['job_id']);
    if (id == null || id.isEmpty) return null;
    return SubtitleTask(
      id: id,
      name: readString(j['name']) ?? id,
      interval: readString(j['interval']) ?? '',
      nextRun:
          readString(j['next_run_in']) ?? readString(j['next_run_time']) ?? '',
      running: readBool(j['job_running']) ?? false,
    );
  }

  /// An item of `GET /api/system/jobs`. `progress` is `value / max` when
  /// Bazarr tracks progress for the job.
  SubtitleJob? job(JsonMap j) {
    final id = readInt(j['job_id']);
    if (id == null) return null;
    final value = readDouble(j['progress_value']);
    final max = readDouble(j['progress_max']);
    final tracked = readBool(j['is_progress']) ?? false;
    final progress = (tracked && value != null && max != null && max > 0)
        ? (value / max).clamp(0.0, 1.0)
        : null;
    return SubtitleJob(
      id: id,
      name: _text(j['job_name']) ?? '',
      status: readString(j['status']) ?? 'unknown',
      progress: progress,
      message: _text(j['progress_message']),
      lastRunAt: readInstant(j['last_run_time']),
    );
  }

  /// `LIVE` → live, anything else → down.
  static SubtitleSignalrState signalr(Object? v) =>
      readString(v)?.trim().toUpperCase() == 'LIVE'
      ? SubtitleSignalrState.live
      : SubtitleSignalrState.down;
}
