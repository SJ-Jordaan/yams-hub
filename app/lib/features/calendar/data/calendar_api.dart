/// Typed wrapper over `GET /calendar` (API.md §9.1).
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_models/yams_models.dart';

class CalendarApi {
  CalendarApi(this.dio);

  final Dio dio;

  /// The agenda between [start] and [end] (calendar dates, both inclusive,
  /// at most 62 days apart). [types] null = episodes and movies.
  Future<CalendarResponse> calendar({
    required DateTime start,
    required DateTime end,
    bool unmonitored = false,
    Set<CalendarItemKind>? types,
  }) => dio.getModel(
    '/calendar',
    CalendarResponse.fromJson,
    query: {
      'start': CalendarDates.format(start),
      'end': CalendarDates.format(end),
      'unmonitored': unmonitored ? 'true' : 'false',
      'types': ?types?.map((t) => t.name).toList(),
    },
  );
}

final calendarApiProvider = Provider<CalendarApi>((ref) => CalendarApi(ref.watch(dioProvider)));
