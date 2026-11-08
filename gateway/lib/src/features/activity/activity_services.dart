/// The state shared by the activity routes: the maindata poller, the *arr
/// queue caches and the small qBittorrent caches (API.md §8).
library;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'activity_history.dart';
import 'maindata.dart';
import 'manual_import.dart';
import 'qbit_mapping.dart';
import 'unified_queue.dart';
import 'vpn_status.dart';

/// One unified-queue computation.
final class QueueComputation {
  const QueueComputation({
    required this.rows,
    required this.qbit,
    required this.qbitStatus,
    this.qbitError,
    required this.arr,
    required this.stale,
  });

  final List<QueueRow> rows;

  /// Null when qBittorrent failed.
  final QbitView? qbit;
  final SectionStatus qbitStatus;

  /// Why qBittorrent failed.
  final Object? qbitError;
  final Map<ArrService, SectionStatus> arr;
  final bool stale;

  /// qBittorrent and every *arr failed: nothing to show.
  bool get allFailed => !qbitStatus.isOk && arr.values.every((s) => !s.isOk);
}

/// Services of the activity feature.
final class ActivityServices {
  ActivityServices(this.ctx)
    : maindata = QbitMaindata(ctx),
      queues = ArrQueueSources(ctx),
      _limits = ctx.caches.ttl<int, TransferLimits>(
        'activity.transfer.limits',
        const Duration(seconds: 60),
      ),
      _prefs = ctx.caches.ttl<int, JsonMap>(
        'activity.qbittorrent.preferences',
        const Duration(minutes: 10),
      ),
      _categories = ctx.caches.ttl<int, CategoryList>(
        'activity.transfer.categories',
        const Duration(seconds: 60),
      ) {
    imports = ManualImportService(ctx, queues);
    history = ActivityHistory(ctx);
    vpn = VpnStatusService(
      ctx,
      maindata,
      preferences,
      () => preferences(fresh: true),
    );
  }

  final FeatureContext ctx;
  final QbitMaindata maindata;
  final ArrQueueSources queues;
  late final ManualImportService imports;
  late final ActivityHistory history;
  late final VpnStatusService vpn;
  final TtlCache<int, TransferLimits> _limits;
  final TtlCache<int, JsonMap> _prefs;
  final TtlCache<int, CategoryList> _categories;

  UpstreamClient get qbit => ctx.upstreams.qbittorrent;

  /// Whitelisted `app/preferences` (cache 10 min; [fresh] reads them now).
  Future<JsonMap> preferences({bool fresh = false}) {
    if (fresh) _prefs.invalidate(0);
    return _loadPreferences();
  }

  Future<JsonMap> _loadPreferences() => _prefs.value(0, () async {
    final body = readMap(await qbit.getJson('/api/v2/app/preferences'));
    return whitelistPreferences(body ?? const {});
  });

  /// `transfer/getSpeedLimits` (cache 60 s).
  Future<TransferLimits> limits() => _limits.value(0, () async {
    final body = readMap(await qbit.getJson('/api/v2/transfer/getSpeedLimits'));
    return transferLimitsOf(body ?? const {});
  });

  void invalidateLimits() => _limits.clear();

  /// `torrents/categories` + `torrents/tags` (cache 60 s).
  Future<CategoryList> categories() => _categories.value(0, () async {
    final results = await Future.wait([
      qbit.getJson('/api/v2/torrents/categories'),
      qbit.getJson('/api/v2/torrents/tags'),
    ]);
    final cats = readMap(results[0]) ?? const {};
    final list = [
      for (final e in cats.entries)
        TorrentCategory(
          name: readString(readMap(e.value)?['name']) ?? e.key,
          savePath: switch (readString(readMap(e.value)?['savePath'])) {
            final p? when p.isNotEmpty => p,
            _ => null,
          },
          readOnly: readOnlyCategories.contains(e.key),
        ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final tags = readStringList(results[1])
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return CategoryList(categories: list, tags: tags);
  });

  void invalidateCategories() => _categories.clear();

  /// The transfer state of [view] with the cached limits and schedule (each
  /// omitted when its call fails).
  Future<TransferState> transferOf(QbitView view) async {
    TransferLimits? limits;
    TransferSchedule? schedule;
    await Future.wait([
      () async {
        try {
          limits = await this.limits();
        } catch (_) {}
      }(),
      () async {
        try {
          schedule = transferScheduleOf(await preferences());
        } catch (_) {}
      }(),
    ]);
    return transferStateOf(
      view.serverState,
      updatedAt: view.updatedAt,
      limits: limits,
      schedule: schedule,
      stale: view.stale,
    );
  }

  /// Merges the torrent snapshot with both *arr queues; failing sources
  /// are reported per source.
  Future<QueueComputation> computeQueue(ApiRequest req) async {
    QbitView? view;
    SectionStatus qbitStatus;
    Object? qbitError;
    final arrFuture = queues.loadAll();
    try {
      view = await maindata.read();
      qbitStatus = const SectionStatus.ok();
    } catch (e) {
      qbitError = e;
      qbitStatus = sectionStatusFor(e, req.requestId);
    }
    final arr = await arrFuture;
    final statuses = <ArrService, SectionStatus>{
      for (final a in arr)
        a.service: a.ok
            ? const SectionStatus.ok()
            : sectionStatusFor(a.error!, req.requestId),
    };
    final rows = buildQueueRows(
      qbit: view,
      groups: groupQueueRecords([
        for (final a in arr)
          if (a.ok) a,
      ]),
      images: ctx.images,
      admin: req.isAdmin,
      redact: ctx.redact,
    );
    return QueueComputation(
      rows: rows,
      qbit: view,
      qbitStatus: qbitStatus,
      qbitError: qbitError,
      arr: statuses,
      stale: (view?.stale ?? false) || arr.any((a) => a.stale),
    );
  }

  /// POSTs a qBittorrent form. With [addressed] an upstream 404 means the
  /// addressed torrent does not exist; 409 is qBittorrent refusing the
  /// action (its text is the reason).
  Future<UpstreamResponse> qbitPost(
    String path, {
    Map<String, String>? form,
    bool addressed = true,
  }) async {
    final r = await qbit.send('POST', path, form: form ?? const {});
    if (r.ok) return r;
    if (r.status == 409) {
      final text = ctx.redact(r.text().trim());
      throw ApiException.conflict(
        text.isEmpty || text.length > 200
            ? 'qBittorrent refused the action.'
            : 'qBittorrent: $text',
      );
    }
    try {
      r.ensureOk();
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: addressed);
    }
    return r;
  }

  void stop() => maindata.stop();
}
