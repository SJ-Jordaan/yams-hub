/// Kavita overview (API.md §14.6; integrations/system.md §7).
///
/// Authenticates with the `x-api-key` Auth Key only. `POST
/// /api/Account/login` is never called (ASP.NET Identity locks the account
/// after repeated failures). Kavita enums arrive as integers and are mapped
/// to named values here.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

/// "Kavita found no series" hint (API.md §14.6).
const kavitaNoSeriesHint =
    'Kavita found no series. It needs one folder per series, e.g. '
    'books/lightnovels/<Series>/<file>.epub';

/// The body Kavita requires for `recently-added-v2` (a read despite POST).
const kavitaRecentlyAddedFilter = {
  'id': 0,
  'name': null,
  'statements': <Object?>[],
  'combination': 1,
  'sortOptions': null,
  'limitTo': 0,
};

/// Reads Kavita.
final class KavitaService {
  KavitaService(this._ctx)
    : _overview = _ctx.caches.ttl<int, BooksOverview>(
        'media.kavita.overview',
        const Duration(seconds: 60),
      );

  final FeatureContext _ctx;
  final TtlCache<int, BooksOverview> _overview;

  UpstreamClient get _kavita => _ctx.upstreams.kavita;

  /// `GET /media/books` (cache 60 s).
  ///
  /// - No `KAVITA_URL`: `503 service_not_configured`.
  /// - URL but no `KAVITA_API_KEY`: `auth: missingKey`, empty lists, no
  ///   upstream call.
  /// - Key rejected (401/403): `auth: rejected`, empty lists.
  Future<BooksOverview> overview() async {
    final config = _ctx.config.service(ServiceId.kavita);
    if (config.url == null) {
      throw ApiException.serviceNotConfigured(ServiceId.kavita);
    }
    if (!config.configured) {
      return _empty(BooksAuth.missingKey);
    }
    return _overview.value(0, _load);
  }

  BooksOverview _empty(BooksAuth auth, {String? version}) => BooksOverview(
    auth: auth,
    version: version ?? _ctx.health.of(ServiceId.kavita)?.version,
    library: const ExternalLink(ExternalApp.kavita, '/'),
  );

  Future<BooksOverview> _load() async {
    final JsonMap? info;
    try {
      info = readMap(await _kavita.getJson('/api/Server/server-info-slim'));
    } on UpstreamException catch (e) {
      if (e.isAuthError) return _empty(BooksAuth.rejected);
      rethrow;
    }
    const page = {'PageNumber': 1, 'PageSize': 12};
    final List<Object?> r;
    try {
      r = await Future.wait<Object?>([
        _kavita.getJson('/api/Library/libraries'),
        _stats(),
        _kavita.sendJson(
          'POST',
          '/api/Series/recently-added-v2',
          query: page,
          body: kavitaRecentlyAddedFilter,
        ),
        _kavita.sendJson(
          'POST',
          '/api/Series/on-deck',
          query: {...page, 'libraryId': 0},
        ),
      ], eagerError: true);
    } on UpstreamException catch (e) {
      if (e.isAuthError) return _empty(BooksAuth.rejected);
      rethrow;
    }
    return mapBooksOverview(
      version: readString(info?['kavitaVersion']),
      libraries: r[0],
      stats: r[1] as JsonMap?,
      recentlyAdded: r[2],
      onDeck: r[3],
      images: _ctx.images,
    );
  }

  /// `/api/Stats/server/stats` needs an admin key; failures leave the stats
  /// out.
  Future<JsonMap?> _stats() async {
    try {
      return readMap(await _kavita.getJson('/api/Stats/server/stats'));
    } on UpstreamException catch (e) {
      if (e is UpstreamNotConfigured) rethrow;
      _ctx.log.fine('Kavita stats unavailable: $e');
      return null;
    }
  }
}

BooksLibraryType _libraryType(Object? v) => switch (readInt(v)) {
  0 => BooksLibraryType.manga,
  1 => BooksLibraryType.comic,
  2 => BooksLibraryType.book,
  3 => BooksLibraryType.image,
  4 => BooksLibraryType.lightNovel,
  5 => BooksLibraryType.comicVine,
  _ => BooksLibraryType.unknown,
};

BookSeriesFormat _format(Object? v) => switch (readInt(v)) {
  0 => BookSeriesFormat.image,
  1 => BookSeriesFormat.archive,
  3 => BookSeriesFormat.epub,
  4 => BookSeriesFormat.pdf,
  _ => BookSeriesFormat.unknown,
};

/// A `SeriesDto` → [BookSeries].
BookSeries? mapBookSeries(
  JsonMap s,
  ImageUrls images, {
  Map<int, String> libraryNames = const {},
}) {
  final id = readInt(s['id']);
  if (id == null || id < 1) return null;
  final libraryId = readInt(s['libraryId']) ?? 0;
  final name = readString(s['localizedName']);
  return BookSeries(
    id: id,
    name: (name == null || name.isEmpty) ? (readString(s['name']) ?? '') : name,
    libraryId: libraryId,
    libraryName: readString(s['libraryName']) ?? libraryNames[libraryId],
    coverPath:
        images.kavitaSeries(id, version: readString(s['lastChapterAdded'])) ??
        '',
    pages: readInt(s['pages']),
    pagesRead: readInt(s['pagesRead']),
    format: _format(s['format']),
    link: ExternalLink(ExternalApp.kavita, '/library/$libraryId/series/$id'),
  );
}

/// Assembles an `auth: ok` [BooksOverview] from the raw Kavita answers.
BooksOverview mapBooksOverview({
  required Object? libraries,
  required JsonMap? stats,
  required Object? recentlyAdded,
  required Object? onDeck,
  required ImageUrls images,
  String? version,
}) {
  final libs = [
    for (final l in readList(libraries, (m) => m))
      if (readInt(l['id']) case final id?)
        BooksLibrary(
          id: id,
          name: readString(l['name']) ?? '',
          type: _libraryType(l['type']),
        ),
  ];
  final names = {for (final l in libs) l.id: l.name};
  List<BookSeries> series(Object? v) => [
    for (final s in readList(v, (m) => m))
      ?mapBookSeries(s, images, libraryNames: names),
  ];
  final st = stats == null
      ? null
      : BooksStats(
          series: readInt(stats['seriesCount']) ?? 0,
          volumes: readInt(stats['volumeCount']) ?? 0,
          chapters: readInt(stats['chapterCount']) ?? 0,
          files: readInt(stats['totalFiles']) ?? 0,
          sizeBytes: readInt(stats['totalSize']) ?? 0,
        );
  final recent = series(recentlyAdded);
  final deck = series(onDeck);
  final noSeries = st == null ? recent.isEmpty && deck.isEmpty : st.series == 0;
  return BooksOverview(
    auth: BooksAuth.ok,
    version: version,
    libraries: libs,
    stats: st,
    recentlyAdded: recent,
    onDeck: deck,
    hint: noSeries ? kavitaNoSeriesHint : null,
    library: ExternalLink(
      ExternalApp.kavita,
      libs.isEmpty ? '/' : '/library/${libs.first.id}',
    ),
  );
}
