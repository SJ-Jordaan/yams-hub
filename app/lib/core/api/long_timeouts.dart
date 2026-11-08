/// Request options for endpoints marked [long] in API.md (up to 150 s).
library;

import 'package:dio/dio.dart';

/// Receive timeout for [long] endpoints (API.md §1.3).
const Duration longReceiveTimeout = Duration(seconds: 160);

/// `Options(receiveTimeout: 160 s)`, merged with any extra [headers].
Options longOptions({Map<String, Object?>? headers}) =>
    Options(receiveTimeout: longReceiveTimeout, headers: headers);
