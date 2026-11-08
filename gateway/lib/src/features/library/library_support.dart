/// Request-body validation, upstream error mapping, list helpers and the
/// command starter shared by the library routes.
library;

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'library_mappers.dart';

/// Typed readers over a JSON body; invalid values are
/// `422 validation_failed` naming the field.
final class LibraryBody {
  LibraryBody(this.json);

  final JsonMap json;

  static Never _invalid(String field, String message) =>
      throw ApiException.invalidField(field, message);

  bool has(String field) => json[field] != null;

  int? optInt(String field, {int? min, int? max}) {
    final raw = json[field];
    if (raw == null) return null;
    final v = raw is int ? raw : (raw is double ? readInt(raw) : null);
    if (v == null) _invalid(field, '$field must be an integer');
    if (min != null && v < min) _invalid(field, '$field must be at least $min');
    if (max != null && v > max) _invalid(field, '$field must be at most $max');
    return v;
  }

  int reqInt(String field, {int? min, int? max}) =>
      optInt(field, min: min, max: max) ??
      _invalid(field, '$field is required');

  bool? optBool(String field) {
    final raw = json[field];
    if (raw == null) return null;
    if (raw is! bool) _invalid(field, '$field must be true or false');
    return raw;
  }

  bool reqBool(String field) =>
      optBool(field) ?? _invalid(field, '$field is required');

  String? optString(String field, {int maxLength = 1000}) {
    final raw = json[field];
    if (raw == null) return null;
    if (raw is! String) _invalid(field, '$field must be a string');
    final s = raw.trim();
    if (s.isEmpty) _invalid(field, '$field must not be empty');
    if (s.length > maxLength) _invalid(field, '$field is too long');
    return s;
  }

  String reqString(String field, {int maxLength = 1000}) =>
      optString(field, maxLength: maxLength) ??
      _invalid(field, '$field is required');

  /// One of [allowed] (exact enum names).
  String? optChoice(String field, List<String> allowed) {
    final raw = json[field];
    if (raw == null) return null;
    if (raw is! String || !allowed.contains(raw)) {
      _invalid(field, '$field must be one of ${allowed.join(', ')}');
    }
    return raw;
  }

  String reqChoice(String field, List<String> allowed) =>
      optChoice(field, allowed) ?? _invalid(field, '$field is required');

  /// A list of positive integers with [minLength]..[maxLength] entries.
  List<int> intList(String field, {int minLength = 1, int maxLength = 500}) {
    final raw = json[field];
    if (raw is! List) _invalid(field, '$field must be a list of ids');
    final out = <int>[];
    for (final v in raw) {
      if (v is! int || v <= 0) _invalid(field, '$field must contain ids');
      if (!out.contains(v)) out.add(v);
    }
    if (out.length < minLength) {
      _invalid(field, '$field needs at least $minLength id(s)');
    }
    if (out.length > maxLength) {
      _invalid(field, '$field accepts at most $maxLength ids');
    }
    return out;
  }

  /// `sonarr` or `radarr`.
  ArrService service([String field = 'service']) =>
      ArrService.fromJson(reqChoice(field, const ['sonarr', 'radarr']));
}

/// Awaits an upstream call and maps its failure. [resourceNotFound]: the
/// gateway path addressed this upstream resource, so an upstream 404 is a
/// 404 ([notFoundMessage]); otherwise it is a 502.
Future<T> arrCall<T>(
  Future<T> call, {
  bool resourceNotFound = false,
  String? notFoundMessage,
}) async {
  try {
    return await call;
  } on UpstreamException catch (e) {
    if (resourceNotFound && e.isNotFound && notFoundMessage != null) {
      throw ApiException(
        404,
        ApiErrorCode.notFound,
        notFoundMessage,
        service: e.service,
      );
    }
    throw e.toApiException(resourceNotFound: resourceNotFound);
  }
}

/// Whether a Servarr add failed because the item is already in the library
/// (`[{"errorMessage": "This series has already been added"}]`).
bool libraryIsAlreadyAdded(UpstreamException e) =>
    (e.status == 400 || e.status == 409 || e.status == 422) &&
    [
      e.message,
      for (final v in e.validation) v.message,
    ].any((m) => m != null && m.toLowerCase().contains('already been added'));

/// `409 already_exists` with `details.libraryId`.
ApiException libraryAlreadyExists(String message, int? libraryId) =>
    ApiException(
      409,
      ApiErrorCode.alreadyExists,
      message,
      details: {'libraryId': ?libraryId},
    );

/// The *arr name of [service] for messages.
String arrName(ArrService service) => service.serviceId.displayName;

/// `ArrService` from the `service` path parameter (`sonarr|radarr`).
ArrService arrServiceParam(ApiRequest req, [String name = 'service']) =>
    switch (req.pathParam(name)) {
      'sonarr' => ArrService.sonarr,
      'radarr' => ArrService.radarr,
      _ => throw ApiException.badRequest('$name must be sonarr or radarr'),
    };

/// Human size for impact texts (decimal units, like the *arr UIs).
String libraryFormatSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  return i == 0 ? '$bytes B' : '${v.toStringAsFixed(1)} ${units[i]}';
}

String libraryPlural(int n, String one, [String? many]) =>
    '$n ${n == 1 ? one : (many ?? '${one}s')}';

const _folds = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a', //
  'ç': 'c', 'č': 'c', 'ć': 'c',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ę': 'e', 'ě': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
  'ñ': 'n', 'ń': 'n', 'ň': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u', 'ů': 'u',
  'ý': 'y', 'ÿ': 'y', 'ž': 'z', 'ź': 'z', 'ż': 'z', 'š': 's', 'ś': 's',
  'ř': 'r', 'ł': 'l', 'đ': 'd', 'ß': 'ss', 'æ': 'ae', 'œ': 'oe',
};

/// Lower-cased, diacritics folded (`Pokémon` → `pokemon`), for `q` filters.
String libraryFold(String s) {
  final lower = s.toLowerCase();
  final sb = StringBuffer();
  for (final ch in lower.split('')) {
    sb.write(_folds[ch] ?? ch);
  }
  return sb.toString();
}

/// Sort direction from `order=asc|desc` (default [defaultAscending]).
bool sortAscending(ApiRequest req, {required bool defaultAscending}) =>
    req.queryChoice('order', const [
      'asc',
      'desc',
    ], defaultValue: defaultAscending ? 'asc' : 'desc') ==
    'asc';

/// Compares nullable values with nulls last in both directions.
int compareNullable<T extends Comparable<Object>>(T? a, T? b, bool ascending) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return ascending ? a.compareTo(b) : b.compareTo(a);
}

/// Starts Sonarr/Radarr commands (`POST /api/v3/command`) with the 30 s
/// gateway debounce of API.md §7.2 and reads their status.
final class LibraryCommands {
  LibraryCommands(this.ctx, this.mapper);

  final FeatureContext ctx;
  final LibraryMapper mapper;
  final _recent = <String, (CommandRef, DateTime)>{};

  static const debounce = Duration(seconds: 30);

  UpstreamClient _client(ArrService svc) =>
      svc == ArrService.sonarr ? ctx.upstreams.sonarr : ctx.upstreams.radarr;

  /// Starts [body] (`{"name": ..., ...}`); an identical body within 30 s
  /// returns the command started first.
  Future<CommandRef> start(ArrService svc, JsonMap body) async {
    final now = ctx.clock.now();
    _recent.removeWhere((_, v) => now.difference(v.$2) >= debounce);
    final key = '${svc.name}:${jsonEncode(body)}';
    final hit = _recent[key];
    if (hit != null) return hit.$1;
    final created = await arrCall(
      _client(svc).sendJson('POST', '/api/v3/command', body: body),
    );
    final ref = mapper.command(svc, arrMap(created, 'command'));
    _recent[key] = (ref, now);
    return ref;
  }

  /// `GET /api/v3/command/{id}`; 404 when the *arr does not know it.
  Future<CommandRef> status(ArrService svc, int id) async {
    final c = await arrCall(
      _client(svc).getJson('/api/v3/command/$id'),
      resourceNotFound: true,
      notFoundMessage: 'Unknown command.',
    );
    return mapper.command(svc, arrMap(c, 'command'));
  }
}

/// `202 {"command": CommandRef}`.
Response commandResponse(CommandRef ref) =>
    ApiResponse.json({'command': ref.toJson()}, status: 202);
