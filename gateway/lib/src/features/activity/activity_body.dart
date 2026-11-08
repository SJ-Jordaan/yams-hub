/// Strict readers for the JSON bodies of the activity write routes: wrong
/// types are `400 bad_request`, values that fail validation `422`.
library;

import 'package:yams_hub_gateway/src/core/http/api_exception.dart';
import 'package:yams_models/yams_models.dart';

/// Wraps a request body.
final class ActivityBody {
  const ActivityBody(this.json);

  final JsonMap json;

  static ApiException _type(String key, String expected) =>
      ApiException.badRequest('$key must be $expected.');

  bool has(String key) => json[key] != null;

  bool? optBool(String key) {
    final v = json[key];
    if (v == null) return null;
    if (v is bool) return v;
    throw _type(key, 'true or false');
  }

  bool reqBool(String key) =>
      optBool(key) ?? (throw ApiException.badRequest('$key is required.'));

  int? optInt(String key, {int? min, int? max}) {
    final v = json[key];
    if (v == null) return null;
    final n = v is int
        ? v
        : (v is double && v == v.truncate() ? v.toInt() : null);
    if (n == null) throw _type(key, 'an integer');
    if (min != null && n < min) {
      throw ApiException.invalidField(key, '$key must be at least $min.');
    }
    if (max != null && n > max) {
      throw ApiException.invalidField(key, '$key must be at most $max.');
    }
    return n;
  }

  int reqInt(String key, {int? min, int? max}) =>
      optInt(key, min: min, max: max) ??
      (throw ApiException.badRequest('$key is required.'));

  double? optDouble(String key, {double? min}) {
    final v = json[key];
    if (v == null) return null;
    if (v is! num || !v.isFinite) throw _type(key, 'a number');
    final d = v.toDouble();
    if (min != null && d < min) {
      throw ApiException.invalidField(key, '$key must be at least $min.');
    }
    return d;
  }

  String? optString(String key) {
    final v = json[key];
    if (v == null) return null;
    if (v is String) return v;
    throw _type(key, 'a string');
  }

  String reqString(String key) =>
      optString(key) ?? (throw ApiException.badRequest('$key is required.'));

  List<Object?>? _list(String key) {
    final v = json[key];
    if (v == null) return null;
    if (v is List) return v;
    throw _type(key, 'an array');
  }

  List<String>? optStringList(String key) {
    final l = _list(key);
    if (l == null) return null;
    return [
      for (final e in l)
        if (e is String) e else throw _type(key, 'an array of strings'),
    ];
  }

  List<int>? optIntList(String key) {
    final l = _list(key);
    if (l == null) return null;
    return [
      for (final e in l)
        if (e is int) e else throw _type(key, 'an array of integers'),
    ];
  }

  List<JsonMap>? optObjects(String key) {
    final l = _list(key);
    if (l == null) return null;
    return [
      for (final e in l)
        if (readMap(e) case final m?)
          m
        else
          throw _type(key, 'an array of objects'),
    ];
  }

  /// An enum by name; [unknown] (the `unknown` member) is never accepted.
  T? optEnum<T extends Enum>(String key, List<T> values, {T? unknown}) {
    final v = json[key];
    if (v == null) return null;
    if (v is String) {
      for (final e in values) {
        if (e != unknown && e.name == v) return e;
      }
    }
    final allowed = [
      for (final e in values)
        if (e != unknown) e.name,
    ];
    throw ApiException.badRequest('$key must be one of ${allowed.join(', ')}.');
  }

  T reqEnum<T extends Enum>(String key, List<T> values, {T? unknown}) =>
      optEnum(key, values, unknown: unknown) ??
      (throw ApiException.badRequest('$key is required.'));

  /// `sonarr` or `radarr`.
  ArrService reqArrService(String key) =>
      reqEnum(key, ArrService.values, unknown: ArrService.unknown);
}
