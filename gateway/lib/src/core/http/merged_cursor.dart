/// Cursor paging over several newest-first upstream feeds
/// (ARCHITECTURE §5.7 "Merged-feed cursors").
library;

import 'dart:convert';

import 'package:yams_models/yams_models.dart';

import '../clock.dart';
import '../ids.dart';
import 'api_exception.dart';

/// Lifetime of a cursor.
const mergedCursorTtl = Duration(minutes: 10);

/// One source's position: the upstream page (1-based) and the index of the
/// next item on it.
final class FeedPosition {
  const FeedPosition({this.page = 1, this.idx = 0, this.done = false});

  final int page;
  final int idx;

  /// No more items in this source.
  final bool done;

  JsonMap toJson() => {'page': page, 'idx': idx, if (done) 'done': true};
}

/// `{"v":1,"exp":<unix>,"s":{"sonarr":{"page":3,"idx":12},...}}` as base64url.
final class MergedCursor {
  const MergedCursor(this.positions, this.expiresAt);

  final Map<String, FeedPosition> positions;
  final DateTime expiresAt;

  String encode() => base64UrlNoPad(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'exp': expiresAt.millisecondsSinceEpoch ~/ 1000,
        's': {for (final e in positions.entries) e.key: e.value.toJson()},
      }),
    ),
  );

  /// Decodes [cursor]; an invalid or expired cursor is `400 bad_request` with
  /// `details.reason: "cursor"`.
  static MergedCursor decode(String cursor, Clock clock) {
    ApiException bad() => ApiException.badRequest(
      'Invalid or expired cursor.',
      details: {'reason': 'cursor'},
    );
    final bytes = decodeBase64UrlNoPad(cursor);
    if (bytes == null) throw bad();
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw bad();
    }
    final m = readMap(json);
    if (m == null || readInt(m['v']) != 1) throw bad();
    final exp = readInt(m['exp']);
    final s = readMap(m['s']);
    if (exp == null || s == null) throw bad();
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      exp * 1000,
      isUtc: true,
    );
    if (!clock.now().isBefore(expiresAt)) throw bad();
    final positions = <String, FeedPosition>{};
    for (final e in s.entries) {
      final p = readMap(e.value);
      final page = readInt(p?['page']);
      final idx = readInt(p?['idx']);
      if (page == null || idx == null || page < 1 || idx < 0) throw bad();
      positions[e.key] = FeedPosition(
        page: page,
        idx: idx,
        done: readBool(p?['done']) ?? false,
      );
    }
    return MergedCursor(positions, expiresAt);
  }
}

/// Loads one upstream page (1-based) of a source, newest first.
typedef FeedPageLoader<T> = Future<List<T>> Function(int page);

/// Merges newest-first [sources] into one page of at most [limit] items.
///
/// Each source's current page (fixed upstream [pageSize]) is loaded; the
/// newest head item across sources is taken repeatedly, advancing that
/// source's index and loading its next page when the index reaches
/// [pageSize]. A source whose page is shorter than [pageSize] ends there.
/// `nextCursor` is absent when every source is exhausted.
Future<CursorPage<T>> mergeFeeds<T>({
  required Map<String, FeedPageLoader<T>> sources,
  required DateTime Function(T item) dateOf,
  required int limit,
  required Clock clock,
  String? cursor,
  int pageSize = 50,
}) async {
  final start = cursor == null ? null : MergedCursor.decode(cursor, clock);
  final pos = <String, FeedPosition>{
    for (final k in sources.keys)
      k: start?.positions[k] ?? const FeedPosition(),
  };
  final pages = <String, List<T>>{};

  Future<void> ensurePage(String k) async {
    var p = pos[k]!;
    while (!p.done) {
      final items = pages[k] ??= await sources[k]!(p.page);
      if (p.idx < items.length) return;
      if (items.length < pageSize) {
        p = FeedPosition(page: p.page, idx: p.idx, done: true);
      } else {
        p = FeedPosition(page: p.page + 1);
        pages.remove(k);
      }
      pos[k] = p;
    }
  }

  final out = <T>[];
  while (out.length < limit) {
    for (final k in sources.keys) {
      await ensurePage(k);
    }
    String? best;
    T? bestItem;
    for (final k in sources.keys) {
      final p = pos[k]!;
      if (p.done) continue;
      final item = pages[k]![p.idx];
      if (bestItem == null || dateOf(item).isAfter(dateOf(bestItem))) {
        best = k;
        bestItem = item;
      }
    }
    if (best == null) break;
    out.add(bestItem as T);
    final p = pos[best]!;
    pos[best] = FeedPosition(page: p.page, idx: p.idx + 1);
  }

  // Normalise positions so exhaustion is detected before handing out a cursor.
  for (final k in sources.keys) {
    await ensurePage(k);
  }
  final allDone = pos.values.every((p) => p.done);
  return CursorPage(
    items: out,
    nextCursor: allDone
        ? null
        : MergedCursor(pos, clock.now().add(mergedCursorTtl)).encode(),
  );
}
