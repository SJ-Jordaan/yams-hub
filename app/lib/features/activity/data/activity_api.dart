/// Typed wrapper over the activity endpoints (API.md §8) plus the two
/// cross-feature calls the Activity screens make: the *arr command poll
/// (`/library/commands`, §7.5) and the gluetun restart (`/containers`, §11.3).
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_models/yams_models.dart';

/// One episode of a series, for the manual-import "Edit match" picker
/// (read from `GET /library/tv/{id}` without the library feature's classes).
class ActivitySeriesEpisode {
  const ActivitySeriesEpisode({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.label,
    this.title,
    this.hasFile = false,
  });

  factory ActivitySeriesEpisode.fromJson(JsonMap j) {
    final season = readInt(j['seasonNumber']) ?? 0;
    final number = readInt(j['episodeNumber']) ?? 0;
    return ActivitySeriesEpisode(
      id: req(readInt(j['id']), 'id'),
      seasonNumber: season,
      episodeNumber: number,
      label: readString(j['label']) ?? ArrEpisodeLabel.format(season, number),
      title: readString(j['title']),
      hasFile: readBool(j['hasFile']) ?? false,
    );
  }

  final int id;
  final int seasonNumber;
  final int episodeNumber;
  final String label;
  final String? title;
  final bool hasFile;
}

/// Query of `GET /torrents`.
typedef TorrentQuery = ({String filter, String? category, String sort, String order});

class ActivityApi {
  ActivityApi(this.dio);

  final Dio dio;

  static String _hash(String hash) => Uri.encodeComponent(hash.toLowerCase());

  // --- queue ---------------------------------------------------------------

  Future<QueueResponse> queue({String filter = 'active', String? category, String? sort}) => dio.getModel(
    '/activity/queue',
    QueueResponse.fromJson,
    query: {'filter': filter, 'category': category, 'sort': sort},
  );

  Future<QueueRemoveResult> removeFromQueue(QueueRemoveRequest request) async =>
      QueueRemoveResult.fromJson(await dio.postMap('/activity/queue/remove', body: request.toJson()));

  Future<void> grab(ArrService service, List<int> queueIds) =>
      dio.postMap('/activity/queue/grab', body: {'service': service.toJson(), 'queueIds': queueIds});

  Future<List<CommandRef>> refreshQueue({ArrService? service}) async {
    final json = await dio.postMap('/activity/queue/refresh', body: {'service': ?service?.toJson()});
    return readList(json['commands'], CommandRef.fromJson);
  }

  Future<ManualImportCandidates> importCandidates(ArrService service, int queueId) => dio.getModel(
    '/activity/queue/${service.name}/$queueId/import',
    ManualImportCandidates.fromJson,
    options: Options(receiveTimeout: const Duration(seconds: 70)),
  );

  Future<CommandRef> manualImport(QueueImportRequest request) async {
    final json = await dio.postMap('/activity/queue/import', body: request.toJson());
    return CommandRef.fromJson(readMap(json['command']) ?? const {'id': 0});
  }

  /// `GET /library/commands/{service}/{id}` (polled after a manual import).
  Future<CommandRef> command(ServiceId service, int id) => dio.getModel(
    '/library/commands/${service.name}/$id',
    (j) => CommandRef.fromJson(readMap(j['command']) ?? (throw const FormatException('command'))),
  );

  /// Episodes of a Sonarr series (`GET /library/tv/{id}`).
  Future<List<ActivitySeriesEpisode>> seriesEpisodes(int seriesId) =>
      dio.getModel('/library/tv/$seriesId', (j) => readList(j['episodes'], ActivitySeriesEpisode.fromJson));

  Future<CursorPage<ArrHistoryItem>> history({
    String service = 'all',
    List<ArrHistoryType> types = const [],
    String? cursor,
    int limit = 25,
  }) => dio.getModel(
    '/activity/history',
    (j) => CursorPage.fromJson(j, ArrHistoryItem.fromJson),
    query: {
      'service': service,
      'types': types.isEmpty ? null : types.map((t) => t.name).toList(),
      'cursor': cursor,
      'limit': limit,
    },
  );

  // --- torrents ------------------------------------------------------------

  Future<TorrentList> torrents(TorrentQuery q) => dio.getModel(
    '/torrents',
    TorrentList.fromJson,
    query: {'filter': q.filter, 'category': q.category, 'sort': q.sort, 'order': q.order},
  );

  Future<TorrentDetail> torrent(String hash) => dio.getModel('/torrents/${_hash(hash)}', TorrentDetail.fromJson);

  Future<void> torrentAction(TorrentActionRequest request) => dio.postMap('/torrents/actions', body: request.toJson());

  Future<void> addTorrents(TorrentAddRequest request) => dio.postMap('/torrents/add', body: request.toJson());

  Future<ShareLimits> setShareLimits(String hash, ShareLimitsUpdate update) async =>
      ShareLimits.fromJson(await dio.putMap('/torrents/${_hash(hash)}/share-limits', body: update.toJson()));

  Future<void> setFilePriority(String hash, List<int> indexes, TorrentFilePriority priority) => dio.putMap(
    '/torrents/${_hash(hash)}/files/priority',
    body: TorrentFilePriorityRequest(indexes: indexes, priority: priority).toJson(),
  );

  // --- transfer and VPN ----------------------------------------------------

  Future<TransferState> transfer() => dio.getModel('/transfer', TransferState.fromJson);

  Future<TransferState> setAltSpeed(bool enabled) async =>
      TransferState.fromJson(await dio.putMap('/transfer/alt-speed', body: {'enabled': enabled}));

  Future<TransferState> setLimits(TransferLimits limits) async =>
      TransferState.fromJson(await dio.putMap('/transfer/limits', body: limits.toJson()));

  Future<TransferState> setSessionPaused(bool paused) async =>
      TransferState.fromJson(await dio.putMap('/transfer/session', body: {'paused': paused}));

  Future<CategoryList> categories() => dio.getModel('/transfer/categories', CategoryList.fromJson);

  Future<VpnStatus> vpn() => dio.getModel('/vpn', VpnStatus.fromJson);

  /// "Restart VPN": the containers feature's gluetun restart job
  /// (`POST /containers/gluetun/actions`, [confirm] for gluetun).
  Future<Job> restartGluetun() async {
    final json = await dio.postMap('/containers/gluetun/actions', body: {'action': 'restart', 'confirm': true});
    return Job.fromJson(readMap(json['job']) ?? (throw const FormatException('job')));
  }
}

final activityApiProvider = Provider<ActivityApi>((ref) => ActivityApi(ref.watch(dioProvider)));
