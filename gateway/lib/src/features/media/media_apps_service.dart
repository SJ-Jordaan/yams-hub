/// `GET /media/apps`: the rich media-app tiles (API.md §14.8).
///
/// Status and version come from the core health report; the headline from
/// the feature's own cached overviews.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'audiobooks_service.dart';
import 'jellyfin_service.dart';
import 'kavita_service.dart';
import 'media_util.dart';
import 'shelfmark_service.dart';

/// Builds the Media > Apps tiles.
final class MediaAppsService {
  MediaAppsService(
    this._ctx, {
    required this.jellyfin,
    required this.audiobooks,
    required this.kavita,
    required this.shelfmark,
  }) : _apps = _ctx.caches.ttl<int, List<MediaApp>>(
         'media.apps',
         const Duration(seconds: 30),
       ),
       _seerrCounts = _ctx.caches.ttl<int, JsonMap>(
         'media.apps.seerrCounts',
         const Duration(seconds: 30),
       );

  final FeatureContext _ctx;
  final JellyfinService jellyfin;
  final AudiobooksService audiobooks;
  final KavitaService kavita;
  final ShelfmarkService shelfmark;
  final TtlCache<int, List<MediaApp>> _apps;
  final TtlCache<int, JsonMap> _seerrCounts;

  /// The five tiles, in display order (cache 30 s).
  Future<List<MediaApp>> apps() => _apps.value(0, () async {
    final report = await _ctx.health.report();
    final headlines = await Future.wait([
      _headline(ServiceId.jellyfin, report, _jellyfinHeadline),
      _headline(ServiceId.audiobookshelf, report, _audiobooksHeadline),
      _headline(ServiceId.kavita, report, _kavitaHeadline),
      _headline(ServiceId.seerr, report, _seerrHeadline),
      _headline(ServiceId.shelfmark, report, _shelfmarkHeadline),
    ]);
    const kinds = [
      MediaAppKind.jellyfin,
      MediaAppKind.audiobookshelf,
      MediaAppKind.kavita,
      MediaAppKind.seerr,
      MediaAppKind.shelfmark,
    ];
    return [
      for (final (i, kind) in kinds.indexed)
        MediaApp(
          app: kind,
          name: kind.externalApp.displayName,
          status: _status(report.of(_service(kind))?.status),
          version: report.of(_service(kind))?.version,
          headline: headlines[i],
          web: ExternalLink(kind.externalApp, '/'),
          route: mediaAppRoutes[kind]!,
        ),
    ];
  });

  static ServiceId _service(MediaAppKind k) => ServiceId.values.byName(k.name);

  static MediaAppStatus _status(ServiceHealthStatus? s) => switch (s) {
    ServiceHealthStatus.up => MediaAppStatus.up,
    ServiceHealthStatus.degraded => MediaAppStatus.degraded,
    ServiceHealthStatus.down => MediaAppStatus.down,
    ServiceHealthStatus.disabled => MediaAppStatus.disabled,
    _ => MediaAppStatus.unknown,
  };

  Future<String> _headline(
    ServiceId id,
    HealthReport report,
    Future<String> Function() build,
  ) async {
    final config = _ctx.config.service(id);
    if (config.url == null) return 'Not configured on the hub';
    final h = report.of(id);
    final fallback = switch (h?.status) {
      ServiceHealthStatus.down => 'Not reachable',
      ServiceHealthStatus.disabled when id != ServiceId.kavita =>
        'Not configured on the hub',
      _ => h?.message ?? 'Details unavailable',
    };
    return await optional(
          build(),
          onError: (e) => _ctx.log.fine('${id.name} headline failed: $e'),
        ) ??
        fallback;
  }

  Future<String> _jellyfinHeadline() async {
    final c = (await jellyfin.shared()).counts;
    return [
      plural(c.movies, 'movie'),
      plural(c.series, 'show'),
      plural(c.episodes, 'episode'),
    ].join(' · ');
  }

  Future<String> _audiobooksHeadline() async {
    final o = await audiobooks.overview();
    final authors = o.libraries.fold(0, (a, l) => a + l.authors);
    return [
      plural(o.totalItems, 'audiobook'),
      plural(authors, 'author'),
      if (o.continueListening.isNotEmpty)
        '${groupThousands(o.continueListening.length)} in progress',
    ].join(' · ');
  }

  Future<String> _kavitaHeadline() async {
    final o = await kavita.overview();
    return switch (o.auth) {
      BooksAuth.missingKey => 'Needs an Auth Key',
      BooksAuth.rejected => 'Kavita rejected the Auth Key',
      _ => switch (o.stats) {
        final s? when s.series > 0 => [
          plural(s.series, 'series', 'series'),
          plural(s.volumes, 'volume'),
        ].join(' · '),
        _ when o.recentlyAdded.isNotEmpty => plural(
          o.recentlyAdded.length,
          'recent series',
          'recent series',
        ),
        _ => 'No series yet',
      },
    };
  }

  /// Seerr `GET /api/v1/request/count` (cache 30 s).
  Future<String> _seerrHeadline() async {
    final c = await _seerrCounts.value(
      0,
      () async =>
          readMap(
            await _ctx.upstreams.seerr.getJson('/api/v1/request/count'),
          ) ??
          const {},
    );
    int n(String k) => readInt(c[k]) ?? 0;
    return [
      '${groupThousands(n('pending'))} pending',
      '${groupThousands(n('processing'))} processing',
      '${groupThousands(n('available'))} available',
    ].join(' · ');
  }

  Future<String> _shelfmarkHeadline() async {
    final s = await shelfmark.status();
    return [
      '${groupThousands(s.queue.active)} downloading',
      '${groupThousands(s.queue.queued)} queued',
      '${groupThousands(s.added.total7d)} added this week',
    ].join(' · ');
  }
}

/// The app route of each tile (APP.md §8.3).
const mediaAppRoutes = {
  MediaAppKind.jellyfin: '/media/jellyfin',
  MediaAppKind.audiobookshelf: '/media/audiobooks',
  MediaAppKind.kavita: '/media/books',
  MediaAppKind.seerr: '/requests',
  MediaAppKind.shelfmark: '/media/shelfmark',
};
