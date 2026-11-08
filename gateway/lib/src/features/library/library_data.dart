/// Cached Sonarr/Radarr reads shared by the library routes (API.md §7).
library;

import 'dart:async';

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'library_mappers.dart';

/// Profile defaults used when Seerr has no service settings (API.md §7.6).
const _fallbackStandardProfile = 9;
const _fallbackAnimeProfile = 7;
const _fallbackMovieProfile = 7;

/// Source name of the synthetic health message for an unreachable *arr.
const libraryUnreachableSource = 'HubConnection';

/// The caches and upstream reads of the library feature.
final class LibraryData {
  LibraryData(this.ctx)
    : mapper = LibraryMapper(ctx.images, redact: ctx.redact),
      _tags = ctx.caches.ttl('library.tags', const Duration(minutes: 10)),
      _profilesRaw = ctx.caches.ttl(
        'library.qualityprofiles',
        const Duration(minutes: 10),
      ),
      _series = ctx.caches.ttl('library.series', const Duration(seconds: 60)),
      _movies = ctx.caches.ttl('library.movies', const Duration(seconds: 60)),
      seriesDetails = ctx.caches.ttl(
        'library.series.detail',
        const Duration(seconds: 30),
        maxEntries: 200,
      ),
      movieDetails = ctx.caches.ttl(
        'library.movie.detail',
        const Duration(seconds: 30),
        maxEntries: 200,
      ),
      lookups = ctx.caches.ttl(
        'library.lookup',
        const Duration(minutes: 10),
        maxEntries: 200,
      ),
      wanted = ctx.caches.ttl(
        'library.wanted',
        const Duration(seconds: 30),
        maxEntries: 200,
      ),
      movieFileQuality = ctx.caches.ttl(
        'library.moviefile.quality',
        const Duration(minutes: 10),
        maxEntries: 500,
      ),
      _profiles = ctx.caches.ttl(
        'library.profiles',
        const Duration(minutes: 10),
      ),
      summaries = ctx.caches.ttl(
        'library.summary',
        const Duration(seconds: 30),
        maxStale: const Duration(minutes: 30),
      );

  final FeatureContext ctx;
  final LibraryMapper mapper;

  final TtlCache<ArrService, Map<int, String>> _tags;
  final TtlCache<ArrService, List<JsonMap>> _profilesRaw;
  final TtlCache<String, List<SeriesSummary>> _series;
  final TtlCache<String, List<MovieSummary>> _movies;
  final TtlCache<int, SeriesDetail> seriesDetails;
  final TtlCache<int, MovieDetail> movieDetails;
  final TtlCache<String, Object> lookups;
  final TtlCache<String, PagedList<WantedItem>> wanted;
  final TtlCache<int, String> movieFileQuality;
  final TtlCache<String, LibraryProfiles> _profiles;
  final TtlCache<String, LibrarySummary> summaries;

  UpstreamClient client(ArrService svc) => switch (svc) {
    ArrService.sonarr => ctx.upstreams.sonarr,
    ArrService.radarr => ctx.upstreams.radarr,
    ArrService.unknown => throw ArgumentError.value(svc, 'svc'),
  };

  UpstreamClient get sonarr => ctx.upstreams.sonarr;
  UpstreamClient get radarr => ctx.upstreams.radarr;

  // -------------------------------------------------------------------------
  // Tags and profiles
  // -------------------------------------------------------------------------

  /// Tag id → label (cached 10 min). A failing tag call yields no labels
  /// rather than failing the list.
  Future<Map<int, String>> tags(ArrService svc) async {
    try {
      return await _tags.value(
        svc,
        () async =>
            LibraryMapper.tagMap(await client(svc).getJson('/api/v3/tag')),
      );
    } on Object catch (e) {
      ctx.log.fine('tags of ${svc.name} unavailable: ${e.runtimeType}');
      return const {};
    }
  }

  /// The full quality profiles (cached 10 min; needed for cutoff names).
  Future<List<JsonMap>> qualityProfiles(ArrService svc) => _profilesRaw.value(
    svc,
    () async => arrList(
      await client(svc).getJson('/api/v3/qualityprofile'),
      'qualityprofile',
    ),
  );

  /// Profile id → name; empty when the profiles cannot be read.
  Future<Map<int, String>> profileNames(ArrService svc) async {
    try {
      return LibraryMapper.profileNames(await qualityProfiles(svc));
    } on Object catch (e) {
      ctx.log.fine('profiles of ${svc.name} unavailable: ${e.runtimeType}');
      return const {};
    }
  }

  /// Profile id → name of its cutoff quality (group names included).
  Future<Map<int, String>> cutoffNames(ArrService svc) async {
    try {
      final profiles = await qualityProfiles(svc);
      return {
        for (final p in profiles)
          ?readInt(p['id']): ?LibraryMapper.cutoffName(p),
      };
    } on Object catch (e) {
      ctx.log.fine('cutoffs of ${svc.name} unavailable: ${e.runtimeType}');
      return const {};
    }
  }

  // -------------------------------------------------------------------------
  // Lists
  // -------------------------------------------------------------------------

  /// Every series (cached 60 s).
  Future<List<SeriesSummary>> series() => _series.value('all', () async {
    final results = await Future.wait<Object?>([
      sonarr.getJson('/api/v3/series'),
      tags(ArrService.sonarr),
      profileNames(ArrService.sonarr),
    ]);
    final tagMap = results[1]! as Map<int, String>;
    final names = results[2]! as Map<int, String>;
    return [
      for (final s in arrList(results[0], 'series'))
        mapper.series(s, tags: tagMap, profiles: names),
    ];
  });

  /// Every movie (cached 60 s; the 1.5 MB upstream list is slimmed here).
  Future<List<MovieSummary>> movies() => _movies.value('all', () async {
    final results = await Future.wait<Object?>([
      radarr.getJson('/api/v3/movie'),
      tags(ArrService.radarr),
      profileNames(ArrService.radarr),
    ]);
    final tagMap = results[1]! as Map<int, String>;
    final names = results[2]! as Map<int, String>;
    return [
      for (final m in arrList(results[0], 'movie'))
        mapper.movie(m, tags: tagMap, profiles: names),
    ];
  });

  /// The cached series list entry for [id] without loading anything.
  SeriesSummary? peekSeries(int? id) {
    if (id == null) return null;
    for (final s in _series.peek('all') ?? const <SeriesSummary>[]) {
      if (s.id == id) return s;
    }
    return seriesDetails.peek(id)?.series;
  }

  /// The cached movie list entry for [id] without loading anything.
  MovieSummary? peekMovie(int? id) {
    if (id == null) return null;
    for (final m in _movies.peek('all') ?? const <MovieSummary>[]) {
      if (m.id == id) return m;
    }
    return movieDetails.peek(id)?.movie;
  }

  // -------------------------------------------------------------------------
  // Invalidation (after every successful write)
  // -------------------------------------------------------------------------

  void invalidateSonarr({int? seriesId}) {
    _series.clear();
    if (seriesId == null) {
      seriesDetails.clear();
    } else {
      seriesDetails.invalidate(seriesId);
    }
    wanted.invalidateWhere((k) => k.startsWith('sonarr:'));
    lookups.invalidateWhere((k) => k.startsWith('tv:'));
    summaries.clear();
  }

  void invalidateRadarr({int? movieId}) {
    _movies.clear();
    if (movieId == null) {
      movieDetails.clear();
    } else {
      movieDetails.invalidate(movieId);
    }
    wanted.invalidateWhere((k) => k.startsWith('radarr:'));
    lookups.invalidateWhere((k) => k.startsWith('movies:'));
    summaries.clear();
  }

  void invalidate(ArrService svc) =>
      svc == ArrService.sonarr ? invalidateSonarr() : invalidateRadarr();

  // -------------------------------------------------------------------------
  // Profiles (API.md §7.6)
  // -------------------------------------------------------------------------

  Future<JsonMap?> _seerrService(String kind) async {
    final seerr = ctx.upstreams.seerr;
    if (!seerr.configured) return null;
    try {
      final list = arrList(
        await seerr.getJson(
          '/api/v1/service/$kind',
          timeout: const Duration(seconds: 5),
        ),
      );
      if (list.isEmpty) return null;
      return list.firstWhere(
        (s) => s['isDefault'] == true && s['is4k'] != true,
        orElse: () =>
            list.firstWhere((s) => s['is4k'] != true, orElse: () => list.first),
      );
    } on Object catch (e) {
      ctx.log.fine(
        'Seerr $kind service settings unavailable: ${e.runtimeType}',
      );
      return null;
    }
  }

  Future<List<LibraryRootFolder>> rootFolders(ArrService svc) async => [
    for (final r in arrList(
      await client(svc).getJson('/api/v3/rootfolder'),
      'rootfolder',
    ))
      if (readInt(r['id']) case final id?)
        LibraryRootFolder(
          id: id,
          path: readString(r['path']) ?? '',
          freeBytes: readInt(r['freeSpace']),
          accessible: readBool(r['accessible']) ?? true,
        ),
  ];

  static String? _pickRoot(List<LibraryRootFolder> roots, String? preferred) {
    if (preferred != null &&
        (roots.isEmpty || roots.any((r) => r.path == preferred))) {
      return preferred;
    }
    return roots.isEmpty ? null : roots.first.path;
  }

  /// `GET /library/profiles` (cached 10 min). An unconfigured *arr has no
  /// profiles or folders and the fallback defaults.
  Future<LibraryProfiles> profiles() => _profiles.value('all', () async {
    Future<(List<LibraryQualityProfile>, List<LibraryRootFolder>)> load(
      ArrService svc,
    ) async {
      if (!client(svc).configured) {
        return (<LibraryQualityProfile>[], <LibraryRootFolder>[]);
      }
      final results = await Future.wait<Object>([
        qualityProfiles(svc),
        rootFolders(svc),
      ]);
      final profiles = [
        for (final p in results[0] as List<JsonMap>)
          if (readInt(p['id']) case final id?)
            LibraryQualityProfile(id: id, name: readString(p['name']) ?? ''),
      ];
      return (profiles, results[1] as List<LibraryRootFolder>);
    }

    final results = await Future.wait<Object?>([
      load(ArrService.sonarr),
      load(ArrService.radarr),
      _seerrService('sonarr'),
      _seerrService('radarr'),
    ]);
    final (sonarrProfiles, sonarrRoots) =
        results[0]! as (List<LibraryQualityProfile>, List<LibraryRootFolder>);
    final (radarrProfiles, radarrRoots) =
        results[1]! as (List<LibraryQualityProfile>, List<LibraryRootFolder>);
    final seerrSonarr = results[2] as JsonMap?;
    final seerrRadarr = results[3] as JsonMap?;
    return LibraryProfiles(
      sonarr: LibrarySonarrProfiles(
        qualityProfiles: sonarrProfiles,
        rootFolders: sonarrRoots,
        defaults: LibrarySonarrDefaults(
          standardProfileId:
              readInt(seerrSonarr?['activeProfileId']) ??
              _fallbackStandardProfile,
          animeProfileId:
              readInt(seerrSonarr?['activeAnimeProfileId']) ??
              readInt(seerrSonarr?['activeProfileId']) ??
              _fallbackAnimeProfile,
          rootFolderPath: _pickRoot(
            sonarrRoots,
            readString(seerrSonarr?['activeDirectory']),
          ),
        ),
      ),
      radarr: LibraryRadarrProfiles(
        qualityProfiles: radarrProfiles,
        rootFolders: radarrRoots,
        defaults: LibraryRadarrDefaults(
          profileId:
              readInt(seerrRadarr?['activeProfileId']) ?? _fallbackMovieProfile,
          rootFolderPath: _pickRoot(
            radarrRoots,
            readString(seerrRadarr?['activeDirectory']),
          ),
        ),
      ),
    );
  });

  /// Defaults for lookups; never fails (fallback values when the profile
  /// read fails).
  Future<LibraryProfiles> profilesOrFallback() async {
    try {
      return await profiles();
    } on Object catch (e) {
      ctx.log.fine('profiles unavailable for suggestions: ${e.runtimeType}');
      return const LibraryProfiles(
        sonarr: LibrarySonarrProfiles(
          qualityProfiles: [],
          rootFolders: [],
          defaults: LibrarySonarrDefaults(
            standardProfileId: _fallbackStandardProfile,
            animeProfileId: _fallbackAnimeProfile,
          ),
        ),
        radarr: LibraryRadarrProfiles(
          qualityProfiles: [],
          rootFolders: [],
          defaults: LibraryRadarrDefaults(profileId: _fallbackMovieProfile),
        ),
      );
    }
  }

  // -------------------------------------------------------------------------
  // Summary (API.md §7.7)
  // -------------------------------------------------------------------------

  Future<ArrSummary> _arrSummary(ArrService svc) async {
    final c = client(svc);
    if (!c.configured) return const ArrSummary.notConfigured();
    final results = await Future.wait<Object?>([
      c.getJson('/api/v3/system/status'),
      c.getJson('/api/v3/health'),
      c.getJson('/api/v3/queue/status'),
      if (svc == ArrService.sonarr)
        c.getJson(
          '/api/v3/wanted/missing',
          query: {'pageSize': 0, 'monitored': true},
        )
      else
        Future<Object?>.value(),
      c.getJson(
        '/api/v3/wanted/cutoff',
        query: {'pageSize': 0, 'monitored': true},
      ),
      rootFolders(svc),
      if (svc == ArrService.sonarr) series() else movies(),
    ]);
    final status = readMap(results[0]) ?? const {};
    final queue = readMap(results[2]) ?? const {};
    final cutoff = readMap(results[4]) ?? const {};
    final roots = results[5]! as List<LibraryRootFolder>;
    final int itemCount;
    final int missing;
    final int size;
    if (svc == ArrService.sonarr) {
      final list = results[6]! as List<SeriesSummary>;
      itemCount = list.length;
      size = list.fold(0, (a, s) => a + s.sizeOnDiskBytes);
      missing =
          readInt(readMap(results[3])?['totalRecords']) ??
          list.fold(0, (a, s) => a + s.missingCount);
    } else {
      final list = results[6]! as List<MovieSummary>;
      itemCount = list.length;
      size = list.fold(0, (a, m) => a + m.sizeOnDiskBytes);
      missing = list
          .where((m) => m.monitored && !m.hasFile && m.isAvailable)
          .length;
    }
    int? free;
    for (final r in roots) {
      final f = r.freeBytes;
      if (f != null && (free == null || f > free)) free = f;
    }
    return ArrSummary(
      configured: true,
      version: readString(status['version']),
      itemCount: itemCount,
      missing: missing,
      cutoffUnmet: readInt(cutoff['totalRecords']) ?? 0,
      sizeOnDiskBytes: size,
      freeBytes: free,
      queue: ArrSummaryQueue(
        total: readInt(queue['totalCount']) ?? 0,
        errors:
            (readBool(queue['errors']) ?? false) ||
            (readBool(queue['unknownErrors']) ?? false),
        warnings:
            (readBool(queue['warnings']) ?? false) ||
            (readBool(queue['unknownWarnings']) ?? false),
      ),
      health: [
        for (final h in arrList(results[1], 'health')) mapper.health(svc, h),
      ],
    );
  }

  /// `GET /library/summary` (cached 30 s). One unreachable *arr becomes a
  /// summary with an error health message; both failing is an error.
  Future<CacheResult<LibrarySummary>> summary() =>
      summaries.get('all', () async {
        Future<(ArrSummary?, Object?)> safe(ArrService svc) async {
          try {
            return (await _arrSummary(svc), null);
          } on Object catch (e) {
            return (null, e);
          }
        }

        final results = await Future.wait([
          safe(ArrService.sonarr),
          safe(ArrService.radarr),
        ]);
        final (sonarrSummary, sonarrError) = results[0];
        final (radarrSummary, radarrError) = results[1];
        if (sonarrSummary == null && radarrSummary == null) {
          throw sonarrError ?? radarrError!;
        }
        ArrSummary orUnreachable(ArrService svc, ArrSummary? s, Object? e) {
          if (s != null) return s;
          return ArrSummary(
            configured: true,
            health: [
              HealthMessage(
                service: svc.serviceId,
                source: libraryUnreachableSource,
                type: HealthMessageType.error,
                message: _errorMessage(svc, e),
              ),
            ],
          );
        }

        return LibrarySummary(
          sonarr: orUnreachable(ArrService.sonarr, sonarrSummary, sonarrError),
          radarr: orUnreachable(ArrService.radarr, radarrSummary, radarrError),
        );
      });

  String _errorMessage(ArrService svc, Object? e) => switch (e) {
    ApiException() => e.message,
    UpstreamException() => e.toApiException(resourceNotFound: false).message,
    _ => '${svc.serviceId.displayName} could not be read.',
  };
}
