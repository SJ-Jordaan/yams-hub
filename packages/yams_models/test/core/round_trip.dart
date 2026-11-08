import 'dart:convert';

import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

/// Sends [json] over the wire (encode + decode) like the gateway and app do.
JsonMap wire(JsonMap json) => jsonDecode(jsonEncode(json)) as JsonMap;

/// Decodes [sample] with [fromJson], re-encodes it and checks that the result
/// equals [sample] and survives a second round trip unchanged.
T expectRoundTrip<T>(
  JsonMap sample,
  T Function(JsonMap) fromJson,
  JsonMap Function(T) toJson,
) {
  final decoded = fromJson(wire(sample));
  final encoded = wire(toJson(decoded));
  expect(encoded, equals(sample), reason: 'toJson(fromJson(sample))');
  expect(wire(toJson(fromJson(encoded))), equals(encoded));
  return decoded;
}
