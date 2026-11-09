/// `/torrents/**`, `/transfer/**` and `/vpn` (API.md §8.4–§8.6).
library;

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'activity_body.dart';
import 'activity_services.dart';
import 'maindata.dart';
import 'qbit_mapping.dart';
import 'unified_queue.dart';

final _hashPattern = RegExp(r'^[0-9a-fA-F]{40}$');

/// Maximum decoded size of one uploaded `.torrent` file.
const maxTorrentFileBytes = 5 * 1024 * 1024;

/// Handlers of the torrent, transfer and VPN routes.
final class TorrentRoutes {
  TorrentRoutes(this._s);

  final ActivityServices _s;

  FeatureContext get _ctx => _s.ctx;

  void register(ApiRouter router) {
    const admin = Role.admin;
    router
      ..get('/torrents', list)
      ..post(
        '/torrents/actions',
        actions,
        role: admin,
        audit: true,
        action: 'activity.torrent.actions',
      )
      ..post(
        '/torrents/add',
        add,
        role: admin,
        audit: true,
        action: 'activity.torrent.add',
      )
      ..get('/torrents/<hash|[0-9a-fA-F]{40}>', detail)
      ..put(
        '/torrents/<hash|[0-9a-fA-F]{40}>/share-limits',
        shareLimits,
        role: admin,
        audit: true,
        action: 'activity.torrent.shareLimits',
      )
      ..put(
        '/torrents/<hash|[0-9a-fA-F]{40}>/files/priority',
        filePriority,
        role: admin,
        audit: true,
        action: 'activity.torrent.filePriority',
      )
      ..get('/transfer', transfer)
      ..get('/transfer/categories', categories)
      ..put(
        '/transfer/alt-speed',
        altSpeed,
        role: admin,
        audit: true,
        action: 'activity.transfer.altSpeed',
      )
      ..put(
        '/transfer/limits',
        limits,
        role: admin,
        audit: true,
        action: 'activity.transfer.limits',
      )
      ..put(
        '/transfer/session',
        session,
        role: admin,
        audit: true,
        action: 'activity.transfer.session',
      )
      ..get('/vpn', vpn);
  }

  // --- reads -----------------------------------------------------------------

  /// `GET /torrents`.
  Future<Response> list(ApiRequest req) async {
    final filter = req.queryChoice(
      'filter',
      torrentFilters,
      defaultValue: 'all',
    );
    final sort = req.queryChoice('sort', torrentSorts, defaultValue: 'added');
    final order = req.queryChoice('order', const [
      'asc',
      'desc',
    ], defaultValue: 'desc');
    final category = req.queryString('category');
    final tag = req.queryString('tag');
    final q = req.queryString('q')?.toLowerCase();
    final view = await _s.maindata.read();
    final working = await _s.trackers.trackerWorking(view);
    final items = [
      for (final t in view.summaries(trackerWorking: working))
        if (torrentMatchesFilter(filter, t) &&
            (category == null || t.category == category) &&
            (tag == null || t.tags.contains(tag)) &&
            (q == null || t.name.toLowerCase().contains(q)))
          t,
    ];
    items.sort((a, b) {
      final c = compareTorrents(sort, a, b);
      final ordered = order == 'asc' ? c : -c;
      return ordered != 0 ? ordered : a.hash.compareTo(b.hash);
    });
    final categories = view.categories.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final tags = List.of(view.tags)
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return ApiResponse.json(
      TorrentList(
        items: items,
        transfer: await _s.transferOf(view),
        categories: categories,
        tags: tags,
        stale: view.stale,
      ).toJson(),
    );
  }

  /// `GET /torrents/{hash}`.
  Future<Response> detail(ApiRequest req) async {
    final hash = req.pathParam('hash').toLowerCase();
    final qbit = _s.qbit;
    // Read in parallel; a failed snapshot only loses the live fields.
    final viewFuture = _s.maindata.read().then<QbitView?>(
      (v) => v,
      onError: (Object _) => null,
    );
    final arrFuture = _s.queues.loadAll();
    final List<Object?> parts;
    try {
      parts = await Future.wait([
        qbit.getJson('/api/v2/torrents/properties', query: {'hash': hash}),
        qbit.getJson('/api/v2/torrents/files', query: {'hash': hash}),
        qbit.getJson('/api/v2/torrents/trackers', query: {'hash': hash}),
      ]);
    } on UpstreamException catch (e) {
      if (e.isNotFound) {
        throw ApiException(
          404,
          ApiErrorCode.notFound,
          'Torrent no longer exists.',
          service: ServiceId.qbittorrent,
        );
      }
      rethrow;
    }
    final props = readMap(parts[0]) ?? const {};
    final trackers = trackersOf([
      for (final t in parts[2] is List ? parts[2] as List : const <Object?>[])
        ?readMap(t),
    ]);
    final working = _s.trackers.record(hash, trackers);
    final view = await viewFuture;
    final raw = view?.torrents[hash] ?? torrentFromProperties(props);
    final summary =
        torrentSummaryOf(hash, raw, trackerWorking: working) ??
        torrentSummaryOf(hash, torrentFromProperties(props));
    if (summary == null) {
      throw ApiException.notFound('Torrent no longer exists.');
    }
    final arr = await arrFuture;
    final entries = [
      for (final g in groupQueueRecords([
        for (final a in arr)
          if (a.ok) a,
      ]))
        if (g.hash == hash)
          queueArrEntryOf(
            g,
            _ctx.images,
            admin: req.isAdmin,
            redact: _ctx.redact,
          ),
    ];
    final comment = readString(props['comment'])?.trim();
    return ApiResponse.json(
      TorrentDetail(
        summary: summary,
        savePath: readString(props['save_path']) ?? '',
        pieceSizeBytes: readInt(props['piece_size']) ?? 0,
        piecesHave: readInt(props['pieces_have']) ?? 0,
        piecesTotal: readInt(props['pieces_num']) ?? 0,
        timeActiveSeconds: readInt(props['time_elapsed']) ?? 0,
        seedingTimeSeconds: readInt(props['seeding_time']) ?? 0,
        wastedBytes: readInt(props['total_wasted']) ?? 0,
        avgDlBps: readInt(props['dl_speed_avg']) ?? 0,
        avgUpBps: readInt(props['up_speed_avg']) ?? 0,
        connections: readInt(props['nb_connections']) ?? 0,
        seedsTotal: readInt(props['seeds_total']) ?? 0,
        peersTotal: readInt(props['peers_total']) ?? 0,
        comment: comment == null || comment.isEmpty
            ? null
            : _ctx.redact(comment),
        isPrivate:
            readBool(props['is_private']) ??
            readBool(props['private']) ??
            false,
        shareLimits: shareLimitsOf(raw),
        files: [
          for (final f
              in parts[1] is List ? parts[1] as List : const <Object?>[])
            if (readMap(f) case final m?) torrentFileOf(m),
        ],
        trackers: trackers,
        arr: entries,
      ).toJson(),
    );
  }

  // --- torrent writes --------------------------------------------------------

  static const _actionPaths = {
    TorrentAction.stop: '/api/v2/torrents/stop',
    TorrentAction.start: '/api/v2/torrents/start',
    TorrentAction.forceStart: '/api/v2/torrents/setForceStart',
    TorrentAction.recheck: '/api/v2/torrents/recheck',
    TorrentAction.reannounce: '/api/v2/torrents/reannounce',
    TorrentAction.delete: '/api/v2/torrents/delete',
    TorrentAction.setCategory: '/api/v2/torrents/setCategory',
    TorrentAction.addTags: '/api/v2/torrents/addTags',
    TorrentAction.removeTags: '/api/v2/torrents/removeTags',
    TorrentAction.topPriority: '/api/v2/torrents/topPrio',
    TorrentAction.bottomPriority: '/api/v2/torrents/bottomPrio',
    TorrentAction.increasePriority: '/api/v2/torrents/increasePrio',
    TorrentAction.decreasePriority: '/api/v2/torrents/decreasePrio',
  };

  /// `POST /torrents/actions`.
  Future<Response> actions(ApiRequest req) async {
    final b = ActivityBody(await req.jsonBody());
    // Audited as `activity.torrent.<action>` (API.md §8.4) once the action
    // is known; an invalid action keeps the route's name.
    final action = b.reqEnum(
      'action',
      TorrentAction.values,
      unknown: TorrentAction.unknown,
    );
    req.auditAction = 'activity.torrent.${action.toJson()}';
    final hashes = b.optStringList('hashes') ?? const [];
    if (hashes.isEmpty || hashes.length > 200) {
      throw ApiException.invalidField('hashes', 'Select 1 to 200 torrents.');
    }
    for (final h in hashes) {
      if (!_hashPattern.hasMatch(h)) {
        throw ApiException.invalidField('hashes', 'Invalid torrent hash.');
      }
    }
    final lower = {for (final h in hashes) h.toLowerCase()}.toList();
    final form = <String, String>{'hashes': lower.join('|')};
    switch (action) {
      case TorrentAction.delete:
        final deleteFiles = b.optBool('deleteFiles') ?? false;
        final n = lower.length;
        final what = n == 1 ? 'the torrent' : '$n torrents';
        await req.requireConfirm(
          deleteFiles
              ? 'Removes $what from qBittorrent and permanently deletes '
                    '${n == 1 ? 'its' : 'their'} files'
              : 'Removes $what from qBittorrent; files stay on disk',
        );
        if (!(b.optBool('force') ?? false)) await _ensureNotManaged(lower);
        form['deleteFiles'] = '$deleteFiles';
      case TorrentAction.forceStart:
        form['value'] = 'true';
      case TorrentAction.setCategory:
        final category = b.optString('category');
        if (category == null) {
          throw ApiException.invalidField('category', 'Choose a category.');
        }
        if (category.isNotEmpty) {
          final view = await _s.maindata.read();
          if (!view.categories.containsKey(category)) {
            throw ApiException.invalidField(
              'category',
              'Category "$category" does not exist in qBittorrent.',
            );
          }
        }
        form['category'] = category;
      case TorrentAction.addTags || TorrentAction.removeTags:
        final tags = [
          for (final t in b.optStringList('tags') ?? const <String>[])
            if (t.trim().isNotEmpty) t.trim(),
        ];
        if (tags.isEmpty || tags.any((t) => t.contains(','))) {
          throw ApiException.invalidField('tags', 'Choose at least one tag.');
        }
        form['tags'] = tags.join(',');
      default:
        break;
    }
    await _s.qbitPost(_actionPaths[action]!, form: form);
    if (action == TorrentAction.delete) _s.queues.invalidate();
    await _s.maindata.refresh();
    return ApiResponse.json({'ok': true});
  }

  /// `409 managed_by_arr` when Sonarr/Radarr still track one of [hashes].
  ///
  /// When a queue cannot be read (the *arr is down or slow), its torrents
  /// cannot be cleared: a torrent in that *arr's category (`tv-sonarr`,
  /// `radarr`) is then refused as well, with `unverified: true`, unless the
  /// delete is forced. Deleting a tracked torrent in qBittorrent makes the
  /// *arr report a missing download or grab the release again.
  Future<void> _ensureNotManaged(List<String> hashes) async {
    final wanted = hashes.toSet();
    final items = <JsonMap>[];
    final sources = await _s.queues.loadAll();
    final unreadable = {
      for (final q in sources)
        if (!q.ok && q.error is! UpstreamNotConfigured) q.service,
    };
    if (unreadable.isNotEmpty) {
      QbitView? view;
      try {
        view = await _s.maindata.read();
      } catch (_) {
        view = null;
      }
      for (final h in wanted) {
        final category = readString(view?.torrents[h]?['category']);
        final service = managedByOf(category);
        // Unknown torrent (no snapshot): every unreadable *arr may track it.
        final suspects = view == null || view.torrents[h] == null
            ? unreadable
            : {?service}.intersection(unreadable);
        for (final svc in suspects) {
          items.add({
            'hash': h,
            'service': svc.name,
            'queueIds': const <int>[],
            'unverified': true,
          });
        }
      }
    }
    for (final g in groupQueueRecords(sources)) {
      final hash = g.hash;
      if (hash == null || !wanted.contains(hash)) continue;
      items.add({
        'hash': hash,
        'service': g.service.name,
        'queueIds': [for (final r in g.records) ?readInt(r['id'])],
      });
    }
    if (items.isEmpty) return;
    final services = {for (final i in items) i['service']};
    final names = services
        .map((s) => s == 'sonarr' ? 'Sonarr' : 'Radarr')
        .join(' and ');
    final unverified = items.every((i) => i['unverified'] == true);
    throw ApiException(
      409,
      ApiErrorCode.managedByArr,
      unverified
          ? '$names could not be checked and may still track this download; '
                'try again, or force the delete.'
          : '$names still track${services.length == 1 ? 's' : ''} this '
                'download; remove it from the queue instead.',
      details: {'items': items},
    );
  }

  /// `POST /torrents/add`.
  Future<Response> add(ApiRequest req) async {
    final b = ActivityBody(await req.jsonBody());
    final urls = [
      for (final u in b.optStringList('urls') ?? const <String>[])
        if (u.trim().isNotEmpty) u.trim(),
    ];
    final files = b.optStringList('torrentFilesBase64') ?? const [];
    if (urls.isEmpty && files.isEmpty) {
      throw ApiException.invalidField(
        'urls',
        'Add at least one magnet link, URL or .torrent file.',
      );
    }
    if (urls.length > 20) {
      throw ApiException.invalidField('urls', 'At most 20 links at once.');
    }
    for (final u in urls) {
      if (!isTorrentLink(u)) {
        throw ApiException.invalidField(
          'urls',
          'Not a magnet link or http(s) URL: ${u.length > 60 ? '${u.substring(0, 60)}…' : u}',
        );
      }
    }
    if (files.length > 5) {
      throw ApiException.invalidField(
        'torrentFilesBase64',
        'At most 5 .torrent files at once.',
      );
    }
    final decoded = <List<int>>[];
    for (final f in files) {
      List<int> bytes;
      try {
        bytes = base64.decode(base64.normalize(f.trim()));
      } on FormatException {
        throw ApiException.invalidField(
          'torrentFilesBase64',
          'A .torrent file is not valid base64.',
        );
      }
      if (bytes.isEmpty || bytes.first != 0x64 /* d */ ) {
        throw ApiException.invalidField(
          'torrentFilesBase64',
          'A file is not a .torrent file.',
        );
      }
      if (bytes.length > maxTorrentFileBytes) {
        throw ApiException.invalidField(
          'torrentFilesBase64',
          'A .torrent file is larger than 5 MB.',
        );
      }
      decoded.add(bytes);
    }
    final category = (b.optString('category') ?? 'manual').trim();
    final tags = [
      for (final t in b.optStringList('tags') ?? const <String>[])
        if (t.trim().isNotEmpty) t.trim(),
    ];
    final stopped = b.optBool('stopped');

    if (category.isNotEmpty) {
      final view = await _s.maindata.read();
      if (!view.categories.containsKey(category)) {
        if (category != 'manual') {
          throw ApiException.invalidField(
            'category',
            'Category "$category" does not exist in qBittorrent.',
          );
        }
        await _createManualCategory();
      }
    }

    final parts = <MultipartPart>[
      if (urls.isNotEmpty) MultipartPart.field('urls', urls.join('\n')),
      for (var i = 0; i < decoded.length; i++)
        MultipartPart.file(
          'torrents',
          'upload-${i + 1}.torrent',
          decoded[i],
          'application/x-bittorrent',
        ),
      if (category.isNotEmpty) MultipartPart.field('category', category),
      if (tags.isNotEmpty) MultipartPart.field('tags', tags.join(',')),
      if (stopped != null) MultipartPart.field('stopped', '$stopped'),
    ];
    final r = await _s.qbit.send(
      'POST',
      '/api/v2/torrents/add',
      multipart: parts,
      timeout: const Duration(seconds: 30),
    );
    if (r.status == 415 || (r.ok && r.text().trim() == 'Fails.')) {
      throw ApiException.validation(
        [
          ApiFieldError(
            field: files.isNotEmpty ? 'torrentFilesBase64' : 'urls',
            message: 'qBittorrent rejected this torrent.',
          ),
        ],
        message: 'qBittorrent rejected this torrent.',
        service: ServiceId.qbittorrent,
      );
    }
    try {
      r.ensureOk();
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: false);
    }
    _s.invalidateCategories();
    await _s.maindata.refresh();
    return ApiResponse.json({'ok': true}, status: 201);
  }

  Future<void> _createManualCategory() async {
    final r = await _s.qbit.send(
      'POST',
      '/api/v2/torrents/createCategory',
      form: const {'category': 'manual', 'savePath': ''},
    );
    // 409: it exists already (created meanwhile).
    if (r.ok || r.status == 409) {
      _s.invalidateCategories();
      return;
    }
    try {
      r.ensureOk();
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: false);
    }
  }

  /// `PUT /torrents/{hash}/share-limits`.
  Future<Response> shareLimits(ApiRequest req) async {
    final hash = req.pathParam('hash').toLowerCase();
    final b = ActivityBody(await req.jsonBody());
    final mode = b.reqEnum(
      'mode',
      ShareLimitsMode.values,
      unknown: ShareLimitsMode.unknown,
    );
    final ratio = b.optDouble('ratio', min: 0);
    final seeding = b.optInt('seedingMinutes', min: 0);
    final inactive = b.optInt('inactiveMinutes', min: 0);
    final rawAction = b.optString('action');
    final action = rawAction == null
        ? ShareLimitsAction.byDefault
        : ShareLimitsAction.tryParse(rawAction) ??
              (throw ApiException.badRequest(
                'action must be one of default, stop, remove, '
                'removeWithContent, enableSuperSeeding.',
              ));
    final custom = mode == ShareLimitsMode.custom;
    if (custom && ratio == null && seeding == null && inactive == null) {
      throw ApiException.invalidField(
        'ratio',
        'Set a ratio, a seeding time or an inactive time.',
      );
    }

    final view = await _s.maindata.read();
    final torrent = view.torrents[hash];
    if (torrent == null) {
      throw ApiException.notFound('Torrent no longer exists.');
    }
    JsonMap prefs;
    try {
      prefs = await _s.preferences();
    } catch (_) {
      prefs = {
        'max_ratio_enabled': (readDouble(torrent['max_ratio']) ?? -1) >= 0,
        'max_ratio': torrent['max_ratio'],
        'max_seeding_time_enabled':
            (readInt(torrent['max_seeding_time']) ?? -1) >= 0,
        'max_seeding_time': torrent['max_seeding_time'],
      };
    }
    final (effectiveRatio, effectiveMinutes) = switch (mode) {
      ShareLimitsMode.global => (
        globalRatioLimit(prefs),
        globalSeedingMinutes(prefs),
      ),
      ShareLimitsMode.custom => (ratio ?? -1.0, seeding ?? -1),
      _ => (-1.0, -1),
    };
    if (action.removes) {
      final name = readString(torrent['name']) ?? hash;
      final conditions = [
        if (effectiveRatio >= 0) 'ratio ≥ ${_ratio(effectiveRatio)}',
        if (effectiveMinutes >= 0)
          'it has seeded for ${_minutes(effectiveMinutes)}',
        if (custom && inactive != null)
          'it has been inactive for ${_minutes(inactive)}',
      ];
      final when = conditions.isEmpty
          ? 'once a share limit is reached'
          : 'once ${conditions.join(' or ')}';
      await req.requireConfirm(
        action == ShareLimitsAction.removeWithContent
            ? 'qBittorrent will delete $name and its files $when'
            : 'qBittorrent removes $name, keeping files, $when',
      );
    }
    final (r, s, i) = switch (mode) {
      ShareLimitsMode.global => ('-2', '-2', '-2'),
      ShareLimitsMode.custom => (
        ratio == null ? '-1' : '$ratio',
        '${seeding ?? -1}',
        '${inactive ?? -1}',
      ),
      _ => ('-1', '-1', '-1'),
    };
    await _s.qbitPost(
      '/api/v2/torrents/setShareLimits',
      form: {
        'hashes': hash,
        'ratioLimit': r,
        'seedingTimeLimit': s,
        'inactiveSeedingTimeLimit': i,
        'shareLimitAction': action.qbit,
        'shareLimitsMode': 'Default',
      },
    );
    await _s.maindata.refresh();
    return ApiResponse.json(
      ShareLimits(
        mode: mode,
        ratio: custom ? ratio : null,
        seedingMinutes: custom ? seeding : null,
        inactiveMinutes: custom ? inactive : null,
        action: action,
        effectiveRatio: effectiveRatio,
        effectiveSeedingMinutes: effectiveMinutes,
      ).toJson(),
    );
  }

  static String _ratio(double r) =>
      r == r.roundToDouble() ? r.toStringAsFixed(1) : '$r';

  static String _minutes(int m) {
    if (m < 60) return '$m min';
    if (m % 1440 == 0) return '${m ~/ 1440} d';
    if (m % 60 == 0) return '${m ~/ 60} h';
    return '$m min';
  }

  /// `PUT /torrents/{hash}/files/priority`.
  Future<Response> filePriority(ApiRequest req) async {
    final hash = req.pathParam('hash').toLowerCase();
    final b = ActivityBody(await req.jsonBody());
    final indexes = b.optIntList('indexes') ?? const [];
    if (indexes.isEmpty || indexes.any((i) => i < 0)) {
      throw ApiException.invalidField('indexes', 'Select at least one file.');
    }
    final priority = b.reqEnum(
      'priority',
      TorrentFilePriority.values,
      unknown: TorrentFilePriority.unknown,
    );
    await _s.qbitPost(
      '/api/v2/torrents/filePrio',
      form: {
        'hash': hash,
        'id': indexes.toSet().join('|'),
        'priority': '${priority.qbit}',
      },
    );
    return ApiResponse.json({'ok': true});
  }

  // --- transfer --------------------------------------------------------------

  /// `GET /transfer`.
  Future<Response> transfer(ApiRequest req) => _transferResponse();

  Future<Response> _transferResponse() async {
    final view = await _s.maindata.read();
    return ApiResponse.json((await _s.transferOf(view)).toJson());
  }

  Future<Response> _transferAfterWrite() async {
    await _s.maindata.refresh();
    return _transferResponse();
  }

  /// `PUT /transfer/alt-speed` (explicit mode, never a toggle).
  Future<Response> altSpeed(ApiRequest req) async {
    final enabled = ActivityBody(await req.jsonBody()).reqBool('enabled');
    await _s.qbitPost(
      '/api/v2/transfer/setSpeedLimitsMode',
      form: {'mode': enabled ? '1' : '0'},
      addressed: false,
    );
    return _transferAfterWrite();
  }

  /// `PUT /transfer/limits`.
  Future<Response> limits(ApiRequest req) async {
    final b = ActivityBody(await req.jsonBody());
    final dl = b.reqInt('dlBps', min: 0);
    final up = b.reqInt('upBps', min: 0);
    final altDl = b.reqInt('altDlBps', min: 0);
    final altUp = b.reqInt('altUpBps', min: 0);
    await _s.qbitPost(
      '/api/v2/transfer/setSpeedLimits',
      form: {
        'up_limit': '$up',
        'dl_limit': '$dl',
        'alt_up_limit': '$altUp',
        'alt_dl_limit': '$altDl',
      },
      addressed: false,
    );
    _s.invalidateLimits();
    return _transferAfterWrite();
  }

  /// `PUT /transfer/session`.
  Future<Response> session(ApiRequest req) async {
    final paused = ActivityBody(await req.jsonBody()).reqBool('paused');
    await _s.qbitPost(
      paused
          ? '/api/v2/transfer/pauseSession'
          : '/api/v2/transfer/resumeSession',
      addressed: false,
    );
    return _transferAfterWrite();
  }

  /// `GET /transfer/categories`.
  Future<Response> categories(ApiRequest req) async =>
      ApiResponse.json((await _s.categories()).toJson());

  /// `GET /vpn`.
  Future<Response> vpn(ApiRequest req) async =>
      ApiResponse.json((await _s.vpn.status()).value.toJson());
}

/// A magnet link (`magnet:?xt=urn:btih:`/`btmh:`) or an http(s) URL with a
/// host. qBittorrent fetches http(s) URLs itself, through the VPN.
bool isTorrentLink(String s) {
  final t = s.trim();
  if (t.toLowerCase().startsWith('magnet:?')) {
    return RegExp(r'xt=urn:bt(ih|mh):', caseSensitive: false).hasMatch(t);
  }
  final u = Uri.tryParse(t);
  return u != null &&
      (u.scheme == 'http' || u.scheme == 'https') &&
      u.host.isNotEmpty &&
      !t.contains(RegExp(r'\s'));
}
