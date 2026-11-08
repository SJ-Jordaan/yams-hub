/// Typed wrapper over the core endpoints (API.md §2, §4).
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_models/yams_models.dart';

import 'api_client.dart';

class CoreApi {
  CoreApi(this.dio);

  final Dio dio;

  Future<LoginResponse> login(LoginRequest request) =>
      dio.getModelPost('/auth/login', request.toJson(), LoginResponse.fromJson);

  Future<void> logout() async => dio.postMap('/auth/logout');

  Future<MeResponse> me() => dio.getModel('/auth/me', MeResponse.fromJson);

  Future<ServerConfig> server() => dio.getModel('/server', ServerConfig.fromJson);

  Future<HealthReport> health() => dio.getModel('/health', HealthReport.fromJson);

  /// `GET /dashboard`; [cards] null = every card.
  Future<DashboardResponse> dashboard({List<String>? cards}) => dio.getModel(
    '/dashboard',
    DashboardResponse.fromJson,
    query: {'cards': ?cards?.join(',')},
  );

  Future<Job> job(String id) => dio.getModel(
    '/jobs/${Uri.encodeComponent(id)}',
    (j) => Job.fromJson(readMap(j['job']) ?? (throw const FormatException('job'))),
  );

  Future<List<Job>> activeJobs({String? kind}) => dio.getModel(
    '/jobs',
    (j) => ItemList.fromJson(j, Job.fromJson).items,
    query: {'active': 'true', 'kind': ?kind},
  );
}

extension on Dio {
  Future<T> getModelPost<T>(String path, Object body, T Function(JsonMap) decode) async {
    final json = await postMap(path, body: body);
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

final coreApiProvider = Provider<CoreApi>((ref) => CoreApi(ref.watch(dioProvider)));
