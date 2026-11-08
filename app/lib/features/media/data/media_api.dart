/// Typed wrapper over the media endpoints (API.md §14).
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_models/yams_models.dart';

class MediaApi {
  MediaApi(this.dio);

  final Dio dio;

  Future<NowPlaying> nowPlaying() => dio.getModel('/media/now-playing', NowPlaying.fromJson);

  /// Pause, resume or stop a session [admin].
  Future<void> playback(String sessionId, MediaPlaybackCommand command) async {
    await dio.postMap('/media/sessions/$sessionId/playback', body: {'command': command.toJson()});
  }

  /// Shows a message on a session's screen [admin].
  Future<void> message(String sessionId, MediaSessionMessage message) async {
    await dio.postMap('/media/sessions/$sessionId/message', body: message.toJson());
  }

  Future<JellyfinOverview> jellyfin() => dio.getModel('/media/jellyfin', JellyfinOverview.fromJson);

  /// Scans every Jellyfin library [admin].
  Future<void> refreshLibraries() async {
    await dio.postMap('/media/jellyfin/library/refresh');
  }

  Future<WatchStats> stats(int days) => dio.getModel('/media/stats', WatchStats.fromJson, query: {'days': days});

  Future<List<WatchUser>> statsUsers() =>
      dio.getModel('/media/stats/users', (j) => ItemList.fromJson(j, WatchUser.fromJson).items);

  /// Playback history; [userId] is honoured for admins only.
  Future<PagedList<PlaybackRecord>> history({int page = 1, int pageSize = 25, String? userId}) => dio.getModel(
    '/media/stats/history',
    (j) => PagedList.fromJson(j, PlaybackRecord.fromJson),
    query: {'page': page, 'pageSize': pageSize, 'userId': userId},
  );

  Future<AudiobooksOverview> audiobooks() => dio.getModel('/media/audiobooks', AudiobooksOverview.fromJson);

  Future<BooksOverview> books() => dio.getModel('/media/books', BooksOverview.fromJson);

  Future<ShelfmarkStatus> shelfmark() => dio.getModel('/media/shelfmark', ShelfmarkStatus.fromJson);

  Future<List<MediaApp>> apps() => dio.getModel('/media/apps', (j) => ItemList.fromJson(j, MediaApp.fromJson).items);
}

final mediaApiProvider = Provider<MediaApi>((ref) => MediaApi(ref.watch(dioProvider)));
