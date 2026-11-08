/// Typed wrapper over the containers endpoints (API.md §11).
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_models/yams_models.dart';

class ContainersApi {
  ContainersApi(this.dio);

  final Dio dio;

  static String _seg(String v) => Uri.encodeComponent(v);

  static Job _job(JsonMap j) => Job.fromJson(readMap(j['job']) ?? (throw const FormatException('job')));

  Future<Job> _postJob(String path, {Object? body, Options? options}) async {
    final json = await dio.postMap(path, body: body ?? const <String, Object?>{}, options: options);
    try {
      return _job(json);
    } on FormatException {
      throw const ApiException(
        status: 0,
        code: ClientErrorCode.badResponse,
        message: 'The hub sent a response this app does not understand.',
      );
    }
  }

  /// `GET /containers`.
  Future<ContainerList> list() => dio.getModel('/containers', ContainerList.fromJson);

  /// `GET /containers/{name}`.
  Future<ContainerDetail> detail(String name) => dio.getModel('/containers/${_seg(name)}', ContainerDetail.fromJson);

  /// `GET /containers/{name}/logs` (admin).
  Future<LogResponse> logs(String name, {int tail = 200, DateTime? since, String stream = 'all'}) => dio.getModel(
    '/containers/${_seg(name)}/logs',
    LogResponse.fromJson,
    query: {'tail': tail, 'stream': stream, 'since': since == null ? null : instantToJson(since)},
  );

  /// `GET /containers/events`.
  Future<List<ContainerEvent>> events({int limit = 50, String? name}) => dio.getModel(
    '/containers/events',
    (j) => ItemList.fromJson(j, ContainerEvent.fromJson).items,
    query: {'limit': limit, 'name': name},
  );

  /// `POST /containers/{name}/actions` (admin); [confirm] after the dialog.
  Future<Job> action(String name, ContainerAction action, {bool confirm = false}) => _postJob(
    '/containers/${_seg(name)}/actions',
    body: ContainerActionRequest(action: action, confirm: confirm ? true : null).toJson(),
  );

  /// `GET /updates`.
  Future<UpdatesResponse> updates() => dio.getModel('/updates', UpdatesResponse.fromJson);

  /// `POST /updates/check` (admin); null [containers] checks every container.
  Future<Job> checkUpdates({List<String>? containers}) =>
      _postJob('/updates/check', body: UpdateCheckRequest(containers: containers).toJson());

  /// `POST /updates/{service}` (admin, confirmed).
  Future<Job> update(String service) => _postJob('/updates/${_seg(service)}', body: const {'confirm': true});

  /// `GET /maintenance/decluttarr`.
  Future<DecluttarrStatus> decluttarr() => dio.getModel('/maintenance/decluttarr', DecluttarrStatus.fromJson);

  /// `GET /maintenance/recyclarr`.
  Future<RecyclarrStatus> recyclarr() => dio.getModel('/maintenance/recyclarr', RecyclarrStatus.fromJson);

  /// `POST /maintenance/recyclarr/sync` (admin, confirmed).
  Future<Job> recyclarrSync() => _postJob('/maintenance/recyclarr/sync', body: const {'confirm': true});
}

final containersApiProvider = Provider<ContainersApi>((ref) => ContainersApi(ref.watch(dioProvider)));
