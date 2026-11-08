/// Typed wrapper over the gateway's `/indexers` endpoints (API.md §10).
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_models/yams_models.dart';

/// Parameters of a manual release search.
class ReleaseSearchQuery {
  const ReleaseSearchQuery({
    required this.query,
    this.type = ReleaseSearchType.search,
    this.indexerIds = const {},
    this.categories = const {},
    this.limit = 100,
  });

  final String query;
  final ReleaseSearchType type;
  final Set<int> indexerIds;
  final Set<int> categories;
  final int limit;

  Map<String, Object?> toQuery() => {
    'q': query.trim(),
    'type': type.name,
    if (indexerIds.isNotEmpty) 'indexerIds': indexerIds.toList()..sort(),
    if (categories.isNotEmpty) 'categories': categories.toList()..sort(),
    'limit': limit,
  };
}

/// One qBittorrent category from `GET /transfer/categories` (activity
/// feature endpoint, read raw: features never import each other's DTOs).
class GrabCategory {
  const GrabCategory(this.name, {this.readOnly = false});

  final String name;
  final bool readOnly;
}

class IndexersApi {
  IndexersApi(this.dio);

  final Dio dio;

  Future<IndexerList> list() => dio.getModel('/indexers', IndexerList.fromJson);

  Future<Indexer> detail(int id) =>
      dio.getModel('/indexers/$id', Indexer.fromJson);

  /// `PATCH /indexers`; answers the fresh list.
  Future<IndexerList> bulkUpdate(IndexerBulkUpdate update) async => _decode(
    await dio.patchMap('/indexers', body: update.toJson()),
    IndexerList.fromJson,
  );

  /// `POST /indexers/{id}/test` → the job.
  Future<Job> test(int id) async =>
      _job(await dio.postMap('/indexers/$id/test'));

  /// `POST /indexers/test-all` → the job.
  Future<Job> testAll() async => _job(await dio.postMap('/indexers/test-all'));

  Future<PagedList<IndexerHistoryItem>> history({
    int page = 1,
    int pageSize = 50,
    IndexerHistoryType? type,
    bool? successful,
    int? indexerId,
  }) => dio.getModel(
    '/indexers/history',
    (j) => PagedList.fromJson(j, IndexerHistoryItem.fromJson),
    query: {
      'page': page,
      'pageSize': pageSize,
      'type': type?.name,
      'successful': successful,
      'indexerId': indexerId,
    },
  );

  Future<List<IndexerCategory>> categories() => dio.getModel(
    '/indexers/categories',
    (j) => ItemList.fromJson(j, IndexerCategory.fromJson).items,
  );

  /// `GET /indexers/search` [long].
  Future<ReleaseList> search(ReleaseSearchQuery query) => dio.getModel(
    '/indexers/search',
    ReleaseList.fromJson,
    query: query.toQuery(),
    options: longOptions(),
  );

  /// `POST /indexers/grab` (the gateway downloads the `.torrent` itself, up to
  /// 60 s, so this uses the long timeout too).
  Future<void> grab(ReleaseGrabRequest request) async {
    await dio.postMap(
      '/indexers/grab',
      body: request.toJson(),
      options: longOptions(),
    );
  }

  /// qBittorrent categories for the grab sheet.
  Future<List<GrabCategory>> qbitCategories() async {
    final json = await dio.getMap('/transfer/categories');
    return [
      for (final c in readList(json['categories'], (m) => m))
        if (readString(c['name']) case final name? when name.isNotEmpty)
          GrabCategory(name, readOnly: readBool(c['readOnly']) ?? false),
    ];
  }

  static Job _job(JsonMap json) =>
      _decode(readMap(json['job']) ?? const {}, Job.fromJson);

  static T _decode<T>(JsonMap json, T Function(JsonMap) decode) {
    try {
      return decode(json);
    } on FormatException {
      throw const ApiException(
        status: 0,
        code: ClientErrorCode.badResponse,
        message: 'The hub sent a response this app does not understand.',
      );
    }
  }
}

final indexersApiProvider = Provider<IndexersApi>(
  (ref) => IndexersApi(ref.watch(dioProvider)),
);
