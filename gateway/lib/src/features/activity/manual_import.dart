/// Manual import of `importBlocked`/`importPending` queue items
/// (API.md §8.3.1, integrations/arr.md §9.1).
///
/// Candidate paths and the raw quality/language objects never leave the
/// gateway: each candidate is kept for 30 min behind an opaque `fileId`
/// token bound to the user who listed it.
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_hub_gateway/src/core/ids.dart';
import 'package:yams_models/yams_models.dart';

import 'activity_body.dart';
import 'arr_mapping.dart';
import 'unified_queue.dart';

/// Lifetime of a `fileId`.
const manualImportTokenTtl = Duration(minutes: 30);

/// `GET /api/v3/manualimport` can parse big season packs for seconds.
const manualImportTimeout = Duration(seconds: 60);

const _maxTokens = 5000;

/// What the gateway remembers about one candidate.
final class ManualImportCandidate {
  ManualImportCandidate({
    required this.userId,
    required this.service,
    required this.queueId,
    required this.expiresAt,
    required this.path,
    required this.downloadId,
    required this.quality,
    required this.languages,
    required this.releaseGroup,
    required this.releaseType,
    required this.seriesId,
    required this.episodeIds,
    required this.movieId,
    required this.indexerFlags,
  });

  final String userId;
  final ArrService service;
  final int queueId;
  final DateTime expiresAt;
  final String path;
  final String downloadId;
  final Object? quality;
  final Object? languages;
  final String? releaseGroup;
  final String? releaseType;
  final int? seriesId;
  final List<int> episodeIds;
  final int? movieId;
  final int indexerFlags;
}

/// Lists candidates and starts `ManualImport` commands.
final class ManualImportService {
  ManualImportService(this._ctx, this._queues);

  final FeatureContext _ctx;
  final ArrQueueSources _queues;
  final _tokens = <String, ManualImportCandidate>{};

  void _prune() {
    final now = _ctx.clock.now();
    _tokens.removeWhere((_, c) => !now.isBefore(c.expiresAt));
    while (_tokens.length > _maxTokens) {
      _tokens.remove(_tokens.keys.first);
    }
  }

  /// `GET /activity/queue/{service}/{queueId}/import`.
  Future<ManualImportCandidates> candidates(
    ApiRequest req,
    ArrService service,
    int queueId,
  ) async {
    final record = await _queues.record(service, queueId);
    if (record == null) {
      throw ApiException.notFound(
        'This download is no longer in the ${_label(service)} queue.',
      );
    }
    final downloadId = readString(record['downloadId']);
    if (downloadId == null || downloadId.isEmpty) {
      throw ApiException.invalidState(
        'This queue item has no download to import from.',
      );
    }
    int? positive(Object? v) => switch (readInt(v)) {
      final n? when n > 0 => n,
      _ => null,
    };
    // Unknown-series/movie items have no id: Sonarr/Radarr then list the
    // files by download alone and the admin picks the series or movie.
    final query = <String, Object?>{
      'downloadId': downloadId,
      if (service == ArrService.sonarr)
        'seriesId': positive(record['seriesId'])
      else
        'movieId': positive(record['movieId']),
      'filterExistingFiles': true,
    };
    final Object? body;
    try {
      body = await _ctx.upstreams
          .arr(service)
          .getJson(
            '/api/v3/manualimport',
            query: query,
            timeout: manualImportTimeout,
          );
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: false);
    }
    _prune();
    final expiresAt = _ctx.clock.now().add(manualImportTokenTtl);
    final items = <ManualImportFile>[];
    for (final raw in body is List ? body : const <Object?>[]) {
      final c = readMap(raw);
      final path = readString(c?['path']);
      if (c == null || path == null) continue;
      items.add(
        _register(
          req.user.id,
          service,
          queueId,
          downloadId,
          path,
          c,
          expiresAt,
        ),
      );
    }
    return ManualImportCandidates(
      service: service,
      queueId: queueId,
      downloadId: downloadId,
      title: readString(record['title']) ?? '',
      items: items,
    );
  }

  ManualImportFile _register(
    String userId,
    ArrService service,
    int queueId,
    String downloadId,
    String path,
    JsonMap c,
    DateTime expiresAt,
  ) {
    final series = readMap(c['series']);
    final movie = readMap(c['movie']);
    final episodes = [
      for (final e
          in c['episodes'] is List ? c['episodes'] as List : const <Object?>[])
        ?readMap(e),
    ];
    final episodeDtos = <ManualImportFileEpisode>[];
    for (final e in episodes) {
      final id = readInt(e['id']);
      final season = readInt(e['seasonNumber']);
      final number = readInt(e['episodeNumber']);
      if (id == null) continue;
      episodeDtos.add(
        ManualImportFileEpisode(
          id: id,
          label: season == null || number == null
              ? '#$id'
              : ArrEpisodeLabel.format(
                  season,
                  number,
                  absoluteEpisodeNumber: readInt(e['absoluteEpisodeNumber']),
                  anime: series?['seriesType'] == 'anime',
                ),
          title: readString(e['title']),
        ),
      );
    }
    final seriesId = readInt(series?['id']);
    final movieId = readInt(movie?['id']);
    final token = 'mi_${randomHex(24)}';
    _tokens[token] = ManualImportCandidate(
      userId: userId,
      service: service,
      queueId: queueId,
      expiresAt: expiresAt,
      path: path,
      downloadId: readString(c['downloadId']) ?? downloadId,
      quality: c['quality'],
      languages: c['languages'],
      releaseGroup: readString(c['releaseGroup']),
      releaseType: readString(c['releaseType']),
      seriesId: seriesId,
      episodeIds: [for (final e in episodeDtos) e.id],
      movieId: movieId,
      indexerFlags: readInt(c['indexerFlags']) ?? 0,
    );
    final rejections = [
      for (final r
          in c['rejections'] is List
              ? c['rejections'] as List
              : const <Object?>[])
        if (readMap(r) case final m?)
          ManualImportFileRejection(
            reason: _ctx.redact(readString(m['reason']) ?? ''),
            type: ManualImportFileRejectionType.fromJson(m['type']),
          ),
    ];
    final relative =
        readString(c['relativePath']) ?? readString(c['name']) ?? '';
    return ManualImportFile(
      fileId: token,
      relativePath: relative,
      sizeBytes: readInt(c['size']) ?? 0,
      quality: arrQualityOf(c['quality']),
      languages: arrLanguagesOf(c['languages']),
      releaseGroup: readString(c['releaseGroup']),
      seriesId: seriesId,
      seasonNumber: readInt(c['seasonNumber']),
      episodes: episodeDtos,
      movieId: movieId,
      movieTitle: readString(movie?['title']),
      customFormatScore: readInt(c['customFormatScore']),
      rejections: rejections,
      importable: service == ArrService.sonarr
          ? seriesId != null && episodeDtos.isNotEmpty
          : movieId != null,
    );
  }

  /// `POST /activity/queue/import` → the started command.
  Future<CommandRef> import(ApiRequest req) async {
    final b = ActivityBody(await req.jsonBody());
    final service = b.reqArrService('service');
    final queueId = b.reqInt('queueId', min: 1);
    final mode =
        b.optEnum(
          'importMode',
          QueueImportMode.values,
          unknown: QueueImportMode.unknown,
        ) ??
        QueueImportMode.auto;
    final files = b.optObjects('files') ?? const [];
    if (files.isEmpty || files.length > 200) {
      throw ApiException.invalidField('files', 'Select 1 to 200 files.');
    }
    _prune();
    final userId = req.user.id;
    final upstreamFiles = <JsonMap>[];
    for (var i = 0; i < files.length; i++) {
      final f = ActivityBody(files[i]);
      final token = f.reqString('fileId');
      final c = _tokens[token];
      if (c == null ||
          c.userId != userId ||
          c.service != service ||
          c.queueId != queueId) {
        throw ApiException.notFound('Import candidates expired, reload.');
      }
      if (service == ArrService.sonarr) {
        final seriesId = f.optInt('seriesId', min: 1) ?? c.seriesId;
        final episodeIds = f.optIntList('episodeIds') ?? c.episodeIds;
        if (seriesId == null || episodeIds.isEmpty) {
          throw ApiException.invalidField(
            'files[$i]',
            'Choose the series and episodes for this file.',
          );
        }
        upstreamFiles.add({
          'path': c.path,
          'seriesId': seriesId,
          'episodeIds': episodeIds,
          'quality': c.quality,
          'languages': c.languages,
          'releaseGroup': c.releaseGroup,
          'downloadId': c.downloadId,
          'indexerFlags': c.indexerFlags,
          'releaseType': _releaseType(c.releaseType, episodeIds.length),
        });
      } else {
        final movieId = f.optInt('movieId', min: 1) ?? c.movieId;
        if (movieId == null) {
          throw ApiException.invalidField(
            'files[$i]',
            'Choose the movie for this file.',
          );
        }
        upstreamFiles.add({
          'path': c.path,
          'movieId': movieId,
          'quality': c.quality,
          'languages': c.languages,
          'releaseGroup': c.releaseGroup,
          'downloadId': c.downloadId,
          'indexerFlags': c.indexerFlags,
        });
      }
    }
    final body = {
      'name': 'ManualImport',
      'importMode': mode.name,
      'files': upstreamFiles,
    };
    final Object? answer;
    try {
      answer = await _ctx.upstreams
          .arr(service)
          .sendJson('POST', '/api/v3/command', body: body);
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: false);
    }
    _queues.invalidate(service);
    final command = readMap(answer);
    if (command == null) {
      throw UpstreamBadResponse(
        service: service.serviceId,
        method: 'POST',
        path: '/api/v3/command',
        reason: 'command answer is not an object',
      );
    }
    return commandRefOf(service, command);
  }

  static String _releaseType(String? candidate, int episodes) {
    const known = {'singleEpisode', 'multiEpisode', 'seasonPack'};
    if (candidate != null && known.contains(candidate)) return candidate;
    return episodes > 1 ? 'multiEpisode' : 'singleEpisode';
  }

  static String _label(ArrService s) =>
      s == ArrService.sonarr ? 'Sonarr' : 'Radarr';
}
