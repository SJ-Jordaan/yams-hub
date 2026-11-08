/// Typed wrapper over the gateway's `/subtitles/**` endpoints (API.md §12).
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_models/yams_models.dart';

/// `type` of `POST /subtitles/search-item`.
enum SubtitleSearchItemType {
  series,
  movie;

  /// The type for the series or movie behind [item].
  static SubtitleSearchItemType of(WantedSubtitle item) => item.type == SubtitleMediaType.movie ? movie : series;
}

class SubtitlesApi {
  SubtitlesApi(this._dio);

  final Dio _dio;

  /// Page size of the wanted and history lists.
  static const pageSize = 25;

  /// `GET /subtitles/summary`.
  Future<SubtitlesSummary> summary() => _dio.getModel('/subtitles/summary', SubtitlesSummary.fromJson);

  /// `GET /subtitles/wanted?type=`.
  Future<PagedList<WantedSubtitle>> wanted(SubtitleListType type, {int page = 1, int size = pageSize}) => _dio.getModel(
    '/subtitles/wanted',
    (j) => PagedList.fromJson(j, WantedSubtitle.fromJson),
    query: {'type': type.toJson(), 'page': page, 'pageSize': size},
  );

  /// `GET /subtitles/history?type=`.
  Future<PagedList<SubtitleHistoryItem>> history(SubtitleListType type, {int page = 1, int size = pageSize}) =>
      _dio.getModel(
        '/subtitles/history',
        (j) => PagedList.fromJson(j, SubtitleHistoryItem.fromJson),
        query: {'type': type.toJson(), 'page': page, 'pageSize': size},
      );

  /// `GET /subtitles/jobs?status=` (`running`, `pending`, `failed`, `completed`).
  Future<List<SubtitleJob>> jobs({String status = 'running'}) async => (await _dio.getModel(
    '/subtitles/jobs',
    (j) => ItemList.fromJson(j, SubtitleJob.fromJson),
    query: {'status': status},
  )).items;

  /// `POST /subtitles/search`: one missing language of an episode or movie.
  Future<void> search(SubtitleSearchRequest request) => _dio.postMap('/subtitles/search', body: request.toJson());

  /// `POST /subtitles/search-item`: every missing language of a series or movie.
  Future<void> searchItem(SubtitleSearchItemType type, int id) =>
      _dio.postMap('/subtitles/search-item', body: {'type': type.name, 'id': id});

  /// `POST /subtitles/search-all` [confirm]: every wanted episode or movie.
  Future<void> searchAll(SubtitleListType type) =>
      _dio.postMap('/subtitles/search-all', body: {'type': type.toJson(), 'confirm': true});

  /// `POST /subtitles/providers/reset`.
  Future<void> resetProviders() => _dio.postMap('/subtitles/providers/reset');

  /// `POST /subtitles/tasks/{taskId}/run`.
  Future<void> runTask(String taskId) => _dio.postMap('/subtitles/tasks/${Uri.encodeComponent(taskId)}/run');
}

final subtitlesApiProvider = Provider<SubtitlesApi>((ref) => SubtitlesApi(ref.watch(dioProvider)));
