/// Typed wrapper over the system endpoints (API.md §13).
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_models/yams_models.dart';

class SystemApi {
  SystemApi(this.dio);

  final Dio dio;

  /// `GET /system/host`.
  Future<HostMetrics> host() => dio.getModel('/system/host', HostMetrics.fromJson);

  /// `GET /system/history?metric=&range=`.
  Future<MetricSeries> history(HostMetricKind metric, HostHistoryRange range) =>
      dio.getModel('/system/history', MetricSeries.fromJson, query: {'metric': metric.toJson(), 'range': range.wire});

  /// `GET /uptime`.
  Future<UptimeResponse> uptime() => dio.getModel('/uptime', UptimeResponse.fromJson);
}

final systemApiProvider = Provider<SystemApi>((ref) => SystemApi(ref.watch(dioProvider)));
