/// The containers feature's logic (API.md §11): Docker reads and control,
/// Watchtower checks, updater jobs and maintenance summaries.
library;

import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_models/yams_models.dart';

import 'container_events.dart';
import 'container_mapper.dart';
import 'container_stats.dart';
import 'decluttarr_parser.dart';
import 'docker_entry.dart';
import 'docker_logs.dart';
import 'recyclarr_parser.dart';
import 'updater.dart';
import 'watchtower.dart';

/// Durations of the feature's background work and long actions; tests use
/// [ContainersTimings.fast].
final class ContainersTimings {
  const ContainersTimings({
    this.actionTimeout = const Duration(seconds: 90),
    this.healthPollInterval = const Duration(seconds: 2),
    this.healthWait = const Duration(seconds: 90),
    this.updaterPollInterval = const Duration(seconds: 3),
    this.updaterTimeout = const Duration(minutes: 45),
    this.initialCheckDelay = const Duration(minutes: 2),
    this.checkInterval = const Duration(hours: 6),
    this.statsInterval = const Duration(seconds: 10),
    this.statsLease = const Duration(seconds: 60),
    this.eventsMinBackoff = const Duration(seconds: 1),
  });

  /// Millisecond polling for tests.
  const ContainersTimings.fast()
    : this(
        healthPollInterval: const Duration(milliseconds: 1),
        healthWait: const Duration(milliseconds: 50),
        updaterPollInterval: const Duration(milliseconds: 1),
        updaterTimeout: const Duration(seconds: 5),
        eventsMinBackoff: const Duration(milliseconds: 10),
      );

  final Duration actionTimeout;
  final Duration healthPollInterval;
  final Duration healthWait;
  final Duration updaterPollInterval;
  final Duration updaterTimeout;
  final Duration initialCheckDelay;
  final Duration checkInterval;
  final Duration statsInterval;
  final Duration statsLease;
  final Duration eventsMinBackoff;
}

/// Rate limit of full Watchtower checks.
const updateCheckMinInterval = Duration(minutes: 5);

/// How to enable Watchtower's check endpoint (integrations/system.md §3.2).
const watchtowerCheckInstructions =
    "Per-container update checks need Watchtower's check endpoint: set "
    'WATCHTOWER_HTTP_API_ENDPOINTS=metrics,check,containers,history in '
    'watchtower.env and remove WATCHTOWER_HTTP_API_METRICS=true.';

/// Shown when the hub's Docker proxy refuses log reads.
const dockerLogsDisabledMessage = 'Logs need ALLOW_LOGS=1 on socket-proxy-hub.';

/// Container names accepted in bodies (same rule as the `{name}` routes).
final containerNamePattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$');

const _defaultRecyclarrSchedule = '0 4 * * 0';

final class ContainersService {
  ContainersService(this.ctx, {this.timings = const ContainersTimings()})
    : _list = ctx.caches.ttl<int, List<DockerContainerEntry>>(
        'containers.list',
        const Duration(seconds: 5),
        maxStale: const Duration(minutes: 2),
      ),
      _engine = ctx.caches.ttl<int, JsonMap>(
        'containers.engine',
        const Duration(seconds: 60),
      ),
      _startedAt = ctx.caches.ttl<String, DateTime?>(
        'containers.startedAt',
        const Duration(minutes: 10),
        maxEntries: 500,
      ),
      _tty = ctx.caches.ttl<String, bool>(
        'containers.tty',
        const Duration(hours: 1),
        maxEntries: 500,
      ),
      _scan = ctx.caches.ttl<int, WatchtowerScan>(
        'containers.watchtowerScan',
        const Duration(seconds: 60),
      ),
      _checkProbe = ctx.caches.ttl<int, bool>(
        'containers.watchtowerCheckProbe',
        const Duration(hours: 6),
        maxStale: Duration.zero,
      ),
      _services = ctx.caches.ttl<int, Set<String>>(
        'containers.updaterServices',
        const Duration(minutes: 10),
      ),
      _decluttarr = ctx.caches.ttl<int, DecluttarrStatus>(
        'containers.decluttarr',
        const Duration(seconds: 60),
      ),
      _recyclarr = ctx.caches.ttl<int, RecyclarrStatus>(
        'containers.recyclarr',
        const Duration(minutes: 5),
      ),
      _card = ctx.caches.ttl<int, DashboardContribution>(
        'containers.card',
        const Duration(seconds: 10),
        maxStale: const Duration(minutes: 5),
      ),
      updates = UpdateResultsStore(ctx.stores.open('updates.json')) {
    _statsPoller = ctx.pollers.create(
      'containers.stats',
      timings.statsInterval,
      timings.statsLease,
      sampleStats,
    );
    _eventStream = ContainerEventStream(
      docker: _docker,
      buffer: events,
      onEvent: _onEvent,
      log: ctx.log,
      minBackoff: timings.eventsMinBackoff,
    );
  }

  final FeatureContext ctx;
  final ContainersTimings timings;

  final TtlCache<int, List<DockerContainerEntry>> _list;
  final TtlCache<int, JsonMap> _engine;
  final TtlCache<String, DateTime?> _startedAt;
  final TtlCache<String, bool> _tty;
  final TtlCache<int, WatchtowerScan> _scan;
  final TtlCache<int, bool> _checkProbe;
  final TtlCache<int, Set<String>> _services;
  final TtlCache<int, DecluttarrStatus> _decluttarr;
  final TtlCache<int, RecyclarrStatus> _recyclarr;
  final TtlCache<int, DashboardContribution> _card;

  /// Watchtower check results (`$DATA/updates.json`).
  final UpdateResultsStore updates;

  /// CPU/memory/network figures from the stats poller.
  final stats = ContainerStatsStore();

  /// The last 1000 container events.
  final events = ContainerEventBuffer();

  late final DemandPoller _statsPoller;
  late final ContainerEventStream _eventStream;
  Timer? _checkTimer;
  DateTime? _lastFullCheckStartedAt;

  DockerClient get _docker => ctx.upstreams.docker;
  UpstreamClient get _watchtower => ctx.upstreams.watchtower;
  UpstreamClient get _updater => ctx.upstreams.updater;
  ContainerPolicy get _policy => ctx.config.policy.containers;

  /// The Docker event stream (tests).
  ContainerEventStream get eventStream => _eventStream;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Opens the event stream and schedules the periodic Watchtower check.
  void start() {
    _eventStream.start();
    _checkTimer?.cancel();
    _checkTimer = Timer(timings.initialCheckDelay, () {
      unawaited(_periodicCheck());
      _checkTimer = Timer.periodic(
        timings.checkInterval,
        (_) => unawaited(_periodicCheck()),
      );
    });
  }

  Future<void> stop() async {
    _checkTimer?.cancel();
    _checkTimer = null;
    _statsPoller.stop();
    await _eventStream.stop();
  }

  void _onEvent(DockerEventRecord r) {
    _list.invalidate(0);
    _card.invalidate(0);
    final action = r.event.action;
    if (const {
      ContainerEventAction.start,
      ContainerEventAction.restart,
      ContainerEventAction.die,
      ContainerEventAction.stop,
      ContainerEventAction.destroy,
    }.contains(action)) {
      _startedAt.invalidate(r.containerId);
    }
    if (action == ContainerEventAction.destroy) _tty.invalidate(r.containerId);
  }

  void _invalidateContainer(String id) {
    _list.invalidate(0);
    _card.invalidate(0);
    _startedAt.invalidate(id);
  }

  // -------------------------------------------------------------------------
  // Docker list and exact-name resolution
  // -------------------------------------------------------------------------

  Future<List<DockerContainerEntry>> _loadList() async {
    final body = await _docker.getJson(
      '/containers/json',
      query: {'all': 'true'},
    );
    if (body is! List) {
      throw UpstreamBadResponse(
        service: ServiceId.docker,
        method: 'GET',
        path: '/containers/json',
        reason: 'not a list',
      );
    }
    return [
      for (final raw in body)
        if (readMap(raw) case final m?) ?DockerContainerEntry.fromJson(m),
    ];
  }

  /// The Docker list (cache 5 s).
  Future<List<DockerContainerEntry>> entries() =>
      _upstream(() => _list.value(0, _loadList));

  Future<CacheResult<List<DockerContainerEntry>>> _entriesResult() =>
      _upstream(() => _list.get(0, _loadList));

  /// Resolves [name] by **exact** container name (`Names[0]` without the
  /// slash) against the list, refreshing it once on a miss. Ids, id
  /// prefixes and anything else are `404 not_found` (API.md §11.6), even
  /// though the Docker Engine would resolve them.
  Future<DockerContainerEntry> resolve(String name) async {
    if (!containerNamePattern.hasMatch(name)) throw _noSuchContainer();
    DockerContainerEntry? find(List<DockerContainerEntry> l) {
      for (final e in l) {
        if (e.name == name) return e;
      }
      return null;
    }

    final cached = find(await entries());
    if (cached != null) return cached;
    _list.invalidate(0);
    return find(await entries()) ?? (throw _noSuchContainer());
  }

  static ApiException _noSuchContainer() =>
      ApiException.notFound('No such container.');

  Future<T> _upstream<T>(
    Future<T> Function() f, {
    bool resourceNotFound = false,
  }) async {
    try {
      return await f();
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: resourceNotFound);
    }
  }

  Future<JsonMap> _inspect(String ref) async {
    final body = await _docker.getJson('/containers/$ref/json');
    return readMap(body) ??
        (throw UpstreamBadResponse(
          service: ServiceId.docker,
          method: 'GET',
          path: '/containers/{name}/json',
          reason: 'not an object',
        ));
  }

  /// `State.StartedAt` of running containers (inspect, cached 10 min per id;
  /// invalidated by start/restart events).
  Future<Map<String, DateTime>> _startTimes(
    List<DockerContainerEntry> list,
  ) async {
    final out = <String, DateTime>{};
    final now = ctx.clock.now();
    await Future.wait([
      for (final e in list)
        if (e.isRunning && e.id.isNotEmpty)
          () async {
            try {
              Future<DateTime?> load() async =>
                  inspectStartedAt(await _inspect(e.id));
              var at = await _startedAt.value(e.id, load);
              // A restart the event stream missed: Docker's (floored)
              // status text says the container is much younger.
              final approx = e.uptimeFromStatus;
              if (at != null && approx != null) {
                final cached = now.difference(at);
                if (cached > approx * 2 + const Duration(minutes: 2)) {
                  _startedAt.invalidate(e.id);
                  at = await _startedAt.value(e.id, load);
                }
              }
              if (at != null) out[e.id] = at;
            } on Exception {
              // Uptime falls back to Docker's status text.
            }
          }(),
    ]);
    return out;
  }

  Map<String, ContainerUpdateFlag> _updateFlags() => {
    for (final r in updates.all)
      if (r.updateAvailable != null)
        r.name: ContainerUpdateFlag(
          available: r.updateAvailable!,
          checkedAt: r.checkedAt,
        ),
  };

  Future<ContainerMappingContext> _mappingContext(
    List<DockerContainerEntry> list, {
    bool withStartTimes = true,
  }) async => ContainerMappingContext(
    policy: _policy,
    now: ctx.clock.now(),
    byId: {for (final e in list) e.id: e},
    stats: stats,
    updates: _updateFlags(),
    startedAt: withStartTimes ? await _startTimes(list) : const {},
  );

  void _touchStats() => unawaited(_statsPoller.touch());

  /// One stats round: a one-shot sample of every running container in
  /// parallel; figures are deltas against the previous round.
  Future<void> sampleStats() async {
    final List<DockerContainerEntry> list;
    try {
      list = await _list.value(0, _loadList);
    } on Exception {
      return;
    }
    final running = [
      for (final e in list)
        if (e.isRunning) e,
    ];
    await Future.wait([
      for (final e in running)
        () async {
          try {
            final body = readMap(
              await _docker.getJson(
                '/containers/${e.id}/stats',
                query: {'stream': 'false', 'one-shot': 'true'},
                timeout: const Duration(seconds: 5),
              ),
            );
            if (body == null) return;
            final s = ContainerStatsSample.fromJson(
              body,
              fallbackRead: ctx.clock.now(),
            );
            if (s != null) stats.add(e.id, s);
          } on Exception {
            // One container failing must not drop the others.
          }
        }(),
    ]);
    stats.retain({for (final e in running) e.id});
  }

  // -------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------

  Future<ContainerEngineInfo> _engineInfo(
    List<DockerContainerEntry> list,
  ) async {
    JsonMap? info;
    try {
      info = await _engine.value(
        0,
        () async => readMap(await _docker.getJson('/info')) ?? const {},
      );
    } on Exception {
      info = null;
    }
    final running = list.where((e) => e.isRunning).length;
    return ContainerEngineInfo(
      version: readString(info?['ServerVersion']) ?? '',
      running: readInt(info?['ContainersRunning']) ?? running,
      stopped:
          readInt(info?['ContainersStopped']) ??
          list.where((e) => !e.isRunning).length,
      total: readInt(info?['Containers']) ?? list.length,
      images: readInt(info?['Images']) ?? 0,
    );
  }

  /// `GET /containers`.
  Future<ContainerList> list({String? group, String? q}) async {
    final all = await entries();
    _touchStats();
    final c = await _mappingContext(all);
    final needle = q?.toLowerCase();
    final items = [for (final e in all) mapContainerSummary(e, c)].where((s) {
      if (group != null && s.group != group) return false;
      if (needle != null &&
          !s.name.toLowerCase().contains(needle) &&
          !s.service.toLowerCase().contains(needle) &&
          !s.image.toLowerCase().contains(needle)) {
        return false;
      }
      return true;
    }).toList()..sort((a, b) => a.name.compareTo(b.name));
    return ContainerList(
      items: items,
      engine: await _engineInfo(all),
      statsAt: stats.sampledAt,
    );
  }

  /// `GET /containers/{name}`.
  Future<ContainerDetail> detail(String name, {required bool admin}) async {
    final e = await resolve(name);
    _touchStats();
    final inspect = await _upstream(
      () => _inspect(e.name),
      resourceNotFound: true,
    );
    final started = inspectStartedAt(inspect);
    if (e.id.isNotEmpty) _startedAt.put(e.id, started);
    final all = await entries();
    final c = await _mappingContext(all, withStartTimes: false);
    return mapContainerDetail(
      e,
      inspect,
      c,
      admin: admin,
      redact: ctx.redact,
      events: events,
    );
  }

  Future<bool> _isTty(DockerContainerEntry e) async {
    try {
      return await _tty.value(
        e.id,
        () async => inspectTty(await _inspect(e.name)),
      );
    } on UpstreamException {
      return false;
    }
  }

  /// Reads and decodes container logs; 403 from the proxy is
  /// `503 service_not_configured` ("Logs need ALLOW_LOGS=1").
  Future<List<DockerLogLine>> _readLogs(
    DockerContainerEntry e, {
    int? tail,
    DateTime? since,
    bool stdout = true,
    bool stderr = true,
  }) async {
    final tty = await _isTty(e);
    final query = <String, Object?>{
      'stdout': stdout ? '1' : '0',
      'stderr': stderr ? '1' : '0',
      'timestamps': '1',
      'tail': tail == null ? null : '$tail',
      'since': since == null
          ? null
          : (since.microsecondsSinceEpoch / 1e6).toStringAsFixed(6),
    };
    final UpstreamResponse r;
    try {
      r = await _docker.send(
        'GET',
        '/containers/${e.name}/logs',
        query: query,
        timeout: const Duration(seconds: 20),
        maxBytes: 16 * 1024 * 1024,
      );
    } on UpstreamException catch (err) {
      throw err.toApiException(resourceNotFound: false);
    }
    if (r.status == 403) {
      throw ApiException.serviceNotConfigured(
        ServiceId.docker,
        dockerLogsDisabledMessage,
      );
    }
    if (!r.ok) {
      throw errorFor(
        ServiceId.docker,
        'GET',
        r.path,
        r.status,
        r.bodyBytes,
        r.contentType,
      ).toApiException();
    }
    return decodeDockerLogs(r.bodyBytes, tty: tty);
  }

  /// `GET /containers/{name}/logs`.
  Future<LogResponse> logs(
    String name, {
    required int tail,
    DateTime? since,
    String stream = 'all',
  }) async {
    final e = await resolve(name);
    final raw = await _readLogs(
      e,
      tail: tail,
      since: since,
      stdout: stream != 'stderr',
      stderr: stream != 'stdout',
    );
    final lines = [
      for (final l in raw)
        if (since == null || l.at == null || l.at!.isAfter(since))
          if (stream == 'all' || l.stream.name == stream)
            LogLine(at: l.at, stream: l.stream, text: ctx.redact(l.text)),
    ];
    return LogResponse(lines: lines, truncated: raw.length >= tail);
  }

  // -------------------------------------------------------------------------
  // Control (API.md §11.3)
  // -------------------------------------------------------------------------

  static String _verb(ContainerAction a) => switch (a) {
    ContainerAction.restart => 'Restart',
    ContainerAction.stop => 'Stop',
    ContainerAction.start => 'Start',
    ContainerAction.unknown => 'Run',
  };

  String _impact(String name, ContainerAction a) {
    if (name == 'gluetun') {
      return switch (a) {
        ContainerAction.stop => 'Stops gluetun: qBittorrent loses network until gluetun is started again.',
        _ =>
          '${_verb(a)}s gluetun, waits until it is healthy and then restarts qBittorrent.',
      };
    }
    return switch (a) {
      ContainerAction.stop => 'Stops $name until it is started again.',
      ContainerAction.restart => 'Restarts $name; it is offline for a moment.',
      _ => 'Starts $name.',
    };
  }

  /// Validates and starts `POST /containers/{name}/actions`.
  Future<JobRecord> startAction(ApiRequest req, String name) async {
    final body = await req.jsonBody();
    final action = ContainerAction.fromJson(body['action']);
    if (action == ContainerAction.unknown) {
      throw ApiException.badRequest('action must be restart, stop or start');
    }
    // The canonical name is used for every check and for the upstream path.
    final canonical = (await resolve(name)).name;
    ctx.health.dockerProxy.ensureActionsAllowed();
    if (_policy.isLocked(canonical)) {
      throw ApiException.policyDenied(
        '$canonical is protected: the hub never stops, restarts or updates it.',
      );
    }
    if (action == ContainerAction.stop || _policy.needsConfirm(canonical)) {
      await req.requireConfirm(_impact(canonical, action));
    }
    return ctx.jobs.start(
      kind: 'containers.${action.name}',
      target: canonical,
      userId: req.user.id,
      run: (h) => _runAction(h, canonical, action),
    );
  }

  Future<void> _dockerAction(String name, ContainerAction action) async {
    final UpstreamResponse r;
    try {
      r = await _docker.send(
        'POST',
        '/containers/$name/${action.name}',
        query: action == ContainerAction.start ? null : {'t': '30'},
        timeout: timings.actionTimeout,
        maxBytes: 64 * 1024,
      );
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: false);
    }
    // 304: already running / already stopped.
    if (r.ok || r.status == 304) return;
    if (r.status == 403) {
      throw ApiException.serviceNotConfigured(
        ServiceId.docker,
        'socket-proxy-hub refused to ${action.name} $name '
        '(needs ALLOW_RESTARTS=1 and ALLOW_START=1).',
      );
    }
    throw errorFor(
      ServiceId.docker,
      'POST',
      r.path,
      r.status,
      r.bodyBytes,
      r.contentType,
    ).toApiException();
  }

  Future<void> _waitHealthy(JobHandle h, String name) async {
    final sw = Stopwatch()..start();
    while (true) {
      try {
        final (state, health) = inspectStateHealth(await _inspect(name));
        if (state == ContainerState.running &&
            (health == ContainerHealth.healthy ||
                health == ContainerHealth.none)) {
          h.log(
            '$name is ${health == ContainerHealth.none ? 'running' : 'healthy'}',
          );
          return;
        }
      } on UpstreamException {
        // Inspect may fail while the container is being restarted.
      }
      if (sw.elapsed >= timings.healthWait) {
        throw ApiException(
          504,
          ApiErrorCode.upstreamTimeout,
          '$name did not become healthy in time; qbittorrent was not restarted.',
          service: ServiceId.docker,
        );
      }
      await Future<void>.delayed(timings.healthPollInterval);
    }
  }

  Future<JsonMap> _runAction(
    JobHandle h,
    String name,
    ContainerAction action,
  ) async {
    final id = (await _safeEntry(name))?.id ?? '';
    h.step('${_verb(action)} $name');
    await _dockerAction(name, action);
    _invalidateContainer(id);
    if (name == 'gluetun' && action != ContainerAction.stop) {
      // qbittorrent shares gluetun's netns: it keeps a dead namespace when
      // gluetun restarts.
      h.step('Wait for gluetun to become healthy');
      await _waitHealthy(h, 'gluetun');
      final qbit = await _safeEntry('qbittorrent');
      if (qbit != null) {
        h.step('Restart qbittorrent');
        await _dockerAction('qbittorrent', ContainerAction.restart);
        _invalidateContainer(qbit.id);
      } else {
        h.log('qbittorrent is not on this host; nothing to restart');
      }
    }
    final inspect = await _inspect(name);
    final (state, health) = inspectStateHealth(inspect);
    return {'state': state.name, 'health': health.name};
  }

  Future<DockerContainerEntry?> _safeEntry(String name) async {
    try {
      for (final e in await _list.value(0, _loadList)) {
        if (e.name == name) return e;
      }
    } on Exception {
      return null;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Updates (API.md §11.4)
  // -------------------------------------------------------------------------

  /// The last Watchtower scan (`/v1/metrics` + `/v1/status`, cache 60 s), or
  /// null when Watchtower is not reachable.
  Future<WatchtowerScan?> lastScan() async {
    if (!_watchtower.configured) return null;
    try {
      return await _scan.value(0, () async {
        final m = await _watchtower.send(
          'GET',
          '/v1/metrics',
          timeout: const Duration(seconds: 5),
          maxBytes: 1 << 20,
        );
        m.ensureOk();
        DateTime? at;
        try {
          final s = await _watchtower.send(
            'GET',
            '/v1/status',
            timeout: const Duration(seconds: 5),
            maxBytes: 1 << 20,
          );
          // 204 before the first scan.
          if (s.status == 200) {
            at = readInstant(readMap(s.json())?['timestamp']);
          }
        } on UpstreamException {
          at = null;
        }
        return parseWatchtowerMetrics(m.text(), at: at);
      });
    } on UpstreamException {
      return null;
    }
  }

  /// Whether Watchtower's `check` endpoint is enabled: probed with
  /// `GET /v1/containers/details` (never `/v1/check`), cached 6 h, and
  /// updated by every check this feature runs.
  Future<bool> checkAvailable() async {
    if (!_watchtower.configured) return false;
    try {
      return await _checkProbe.value(0, () async {
        final r = await _watchtower.send(
          'GET',
          '/v1/containers/details',
          timeout: const Duration(seconds: 5),
          maxBytes: 1 << 20,
        );
        if (r.status == 404) return false;
        r.ensureOk();
        return true;
      });
    } on Exception {
      return ctx.health.features.watchtowerCheck;
    }
  }

  /// The updater's allow-list (`GET /services`, cache 10 min), or null when
  /// the updater is not configured or not reachable.
  Future<Set<String>?> updaterServices() async {
    if (!_updater.configured) return null;
    try {
      return await _services.value(0, () async {
        final body = readMap(
          await _updater.getJson(
            '/services',
            timeout: const Duration(seconds: 3),
          ),
        );
        return {
          for (final s in readStringList(body?['services']))
            if (updaterServicePattern.hasMatch(s)) s,
        };
      });
    } on Exception {
      return null;
    }
  }

  bool get _checking =>
      ctx.jobs.list(activeOnly: true, kindPrefix: 'updates.check').isNotEmpty;

  /// `GET /updates`.
  Future<UpdatesResponse> updatesOverview() async {
    List<DockerContainerEntry>? list;
    try {
      list = await _list.value(0, _loadList);
    } on Exception {
      list = null;
    }
    final results = await Future.wait<Object?>([
      lastScan(),
      checkAvailable(),
      updaterServices(),
    ]);
    final scan = results[0] as WatchtowerScan?;
    final available = results[1]! as bool;
    final services = results[2] as Set<String>?;
    final items = <UpdateInfo>[];
    if (list != null) {
      for (final e in list) {
        final r = updates.of(e.name);
        items.add(
          UpdateInfo(
            name: e.name,
            image: e.image,
            updateAvailable: r?.updateAvailable,
            pinned: e.pinned,
            currentVersion: e.imageVersion ?? r?.currentVersion,
            currentDigest: r?.currentDigest,
            latestDigest: r?.latestDigest,
            error: r?.error,
            autoUpdate: e.autoUpdate,
            canUpdate:
                services != null &&
                services.contains(e.service) &&
                !_policy.isLocked(e.name) &&
                !_policy.isLocked(e.service),
          ),
        );
      }
    } else {
      // Docker is unreachable: show what the last check knew.
      for (final r in updates.all) {
        items.add(
          UpdateInfo(
            name: r.name,
            image: r.image ?? '',
            updateAvailable: r.updateAvailable,
            currentVersion: r.currentVersion,
            currentDigest: r.currentDigest,
            latestDigest: r.latestDigest,
            error: r.error,
          ),
        );
      }
    }
    items.sort((a, b) {
      // Updates first, then by name.
      final ua = a.updateAvailable ?? false;
      final ub = b.updateAvailable ?? false;
      if (ua != ub) return ua ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return UpdatesResponse(
      checkedAt: updates.checkedAt,
      checking: _checking,
      available: available,
      items: items,
      updaterAvailable: services != null,
      lastScan: scan,
    );
  }

  /// Validates and starts `POST /updates/check`.
  Future<JobRecord> startCheck(ApiRequest req) async {
    if (!_watchtower.configured) {
      throw ApiException.serviceNotConfigured(ServiceId.watchtower);
    }
    final body = await req.jsonBody();
    List<String>? containers;
    final raw = body['containers'];
    if (raw != null) {
      if (raw is! List || raw.any((c) => c is! String)) {
        throw ApiException.badRequest('containers must be a list of names');
      }
      containers = {
        for (final c in raw.cast<String>())
          if (c.trim().isNotEmpty) c.trim(),
      }.toList()..sort();
      for (final c in containers) {
        if (!containerNamePattern.hasMatch(c)) {
          throw ApiException.badRequest('invalid container name');
        }
      }
      if (containers.isEmpty) containers = null;
    }
    if (containers == null) {
      final now = ctx.clock.now();
      final last = [updates.lastFullCheckAt, _lastFullCheckStartedAt]
          .whereType<DateTime>()
          .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
      final running = ctx.jobs
          .list(activeOnly: true, kindPrefix: 'updates.check')
          .where((j) => j.target == null)
          .firstOrNull;
      if (running != null) return running;
      if (last != null && now.difference(last) < updateCheckMinInterval) {
        final wait = updateCheckMinInterval - now.difference(last);
        throw ApiException.rateLimited(
          wait.inSeconds + 1,
          'Containers were checked less than 5 minutes ago.',
        );
      }
    }
    if (!await checkAvailable()) {
      throw ApiException.serviceNotConfigured(
        ServiceId.watchtower,
        watchtowerCheckInstructions,
      );
    }
    return _startCheckJob(containers, userId: req.user.id);
  }

  JobRecord _startCheckJob(List<String>? containers, {String? userId}) {
    if (containers == null) _lastFullCheckStartedAt = ctx.clock.now();
    return ctx.jobs.start(
      kind: 'updates.check',
      target: containers?.join(','),
      userId: userId,
      run: (h) => _runCheck(h, containers),
    );
  }

  Future<JsonMap> _runCheck(JobHandle h, List<String>? containers) async {
    h.step(
      containers == null
          ? 'Check every container for updates'
          : 'Check ${containers.join(', ')} for updates',
    );
    final r = await _watchtower.send(
      'POST',
      '/v1/check',
      query: {
        'timeout': '2m',
        if (containers != null) 'container': containers.join(','),
      },
      timeout: const Duration(seconds: 150),
      maxBytes: 4 * 1024 * 1024,
    );
    if (r.status == 404) {
      _checkProbe.put(0, false);
      throw ApiException.serviceNotConfigured(
        ServiceId.watchtower,
        watchtowerCheckInstructions,
      );
    }
    r.ensureOk();
    _checkProbe.put(0, true);
    final now = ctx.clock.now();
    final body = readMap(r.json()) ?? const {};
    final results = [
      for (final c in readList(body['containers'], (m) => m))
        ?UpdateCheckResult.fromWatchtower(c, now, ctx.redact),
    ];
    await updates.record(results, full: containers == null, at: now);
    _card.invalidate(0);
    final available = results.where((x) => x.updateAvailable ?? false).length;
    final failed = results.where((x) => x.error != null).length;
    h.log(
      'Checked ${results.length} containers: $available with updates'
      '${failed > 0 ? ', $failed failed' : ''}',
    );
    return {
      'checked': results.length,
      'updatesAvailable': available,
      'failed': failed,
    };
  }

  Future<void> _periodicCheck() async {
    try {
      final last = updates.lastFullCheckAt;
      final now = ctx.clock.now();
      if (last != null &&
          now.difference(last) <
              timings.checkInterval - updateCheckMinInterval) {
        return;
      }
      if (!await checkAvailable()) return;
      _startCheckJob(null);
    } on Exception catch (e) {
      ctx.log.warning('periodic update check failed to start: $e');
    }
  }

  void _requireUpdater() {
    if (!_updater.configured) {
      throw ApiException.serviceNotConfigured(
        ServiceId.updater,
        'The updater sidecar is not configured; run `yams update-containers` on the NAS.',
      );
    }
  }

  /// Validates and starts `POST /updates/{service}`.
  Future<JobRecord> startUpdate(ApiRequest req, String service) async {
    _requireUpdater();
    if (!updaterServicePattern.hasMatch(service)) {
      throw ApiException.notFound('No such service.');
    }
    // Locked services are refused whether or not the updater lists them.
    await _ensureUpdatable(service);
    final Set<String> allowed;
    try {
      allowed = await _services.value(0, () async {
        final body = readMap(
          await _updater.getJson(
            '/services',
            timeout: const Duration(seconds: 5),
          ),
        );
        return {
          for (final s in readStringList(body?['services']))
            if (updaterServicePattern.hasMatch(s)) s,
        };
      });
    } on UpstreamException catch (e) {
      throw e.toApiException(resourceNotFound: false);
    }
    var target = service;
    if (!allowed.contains(target)) {
      // The app addresses rows by container name (UpdateInfo.name); map an
      // exact container name to its compose service, which must itself be
      // in the allow-list.
      final byName = await _safeEntry(service);
      if (byName == null || !allowed.contains(byName.service)) {
        throw ApiException.notFound('The updater does not manage $service.');
      }
      target = byName.service;
      await _ensureUpdatable(target);
    }
    await req.requireConfirm(
      'Pulls the latest image and recreates $target; it is offline for a moment.',
    );
    return ctx.jobs.start(
      kind: 'updates.apply',
      target: target,
      userId: req.user.id,
      run: (h) => _runUpdate(h, target),
    );
  }

  /// `403 policy_denied` when [service] or one of its containers is locked.
  Future<void> _ensureUpdatable(String service) async {
    final names = await _containersOfService(service);
    if (_policy.isLocked(service) || names.any(_policy.isLocked)) {
      throw ApiException.policyDenied(
        '$service is protected: the hub never updates it.',
      );
    }
  }

  Future<List<String>> _containersOfService(String service) async {
    try {
      return [
        for (final e in await _list.value(0, _loadList))
          if (e.service == service || e.name == service) e.name,
      ];
    } on Exception {
      return [service];
    }
  }

  Future<String> _startUpdaterJob(String path, {Object? body}) async {
    final r = await _updater.send(
      'POST',
      path,
      jsonBody: body ?? const <String, Object?>{},
      timeout: const Duration(seconds: 30),
      maxBytes: 64 * 1024,
    );
    if (r.status == 409) {
      throw ApiException.jobRunning('The updater is busy with another job.');
    }
    if (r.status == 404) {
      throw ApiException.notFound('The updater refused this target.');
    }
    r.ensureOk();
    final id = readString(readMap(r.json())?['jobId']);
    if (id == null || !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id)) {
      throw UpstreamBadResponse(
        service: ServiceId.updater,
        method: 'POST',
        path: path,
        reason: 'no jobId',
      );
    }
    return id;
  }

  Future<JsonMap> _runUpdate(JobHandle h, String service) async {
    h.step('Ask the updater to update $service');
    final updaterJob = await _startUpdaterJob(
      '/update/$service',
      body: {'service': service},
    );
    h.log('Updater job $updaterJob started');
    await UpdaterJobMirror(
      updater: _updater,
      handle: h,
      pollInterval: timings.updaterPollInterval,
      timeout: timings.updaterTimeout,
    ).follow(updaterJob, what: 'The update of $service');
    _list.invalidate(0);
    _card.invalidate(0);
    final names = await _containersOfService(service);
    if (names.isNotEmpty && await checkAvailable()) {
      try {
        await _runCheck(h, names);
      } on Exception catch (e) {
        h.log('The follow-up update check failed: $e');
      }
    }
    return {'service': service, 'state': 'updated'};
  }

  // -------------------------------------------------------------------------
  // Maintenance (API.md §11.5)
  // -------------------------------------------------------------------------

  MaintenanceContainerState _stateOf(DockerContainerEntry? e) =>
      MaintenanceContainerState(
        state: e?.state ?? ContainerState.unknown,
        health: e?.health ?? ContainerHealth.unknown,
      );

  /// `GET /maintenance/decluttarr` (cache 60 s).
  Future<CacheResult<DecluttarrStatus>> decluttarr() => _upstream(
    () => _decluttarr.get(0, () async {
      final e = await _safeEntryOrThrow('decluttarr');
      final lines = await _readLogs(
        e,
        since: ctx.clock.now().subtract(const Duration(hours: 24)),
      );
      return parseDecluttarrLog(
        lines,
        container: _stateOf(e),
        redact: ctx.redact,
      );
    }),
  );

  Future<DockerContainerEntry> _safeEntryOrThrow(String name) async {
    for (final e in await _list.value(0, _loadList)) {
      if (e.name == name) return e;
    }
    throw ApiException.notFound('There is no $name container on this host.');
  }

  /// `GET /maintenance/recyclarr` (cache 5 min).
  Future<CacheResult<RecyclarrStatus>>
  recyclarr() => _recyclarr.get(0, () async {
    final e = await _safeEntry('recyclarr');
    var schedule = _defaultRecyclarrSchedule;
    if (e != null) {
      try {
        // Only CRON_SCHEDULE is read; Config.Env never leaves the gateway.
        final env = readStringList(
          readMap((await _inspect(e.name))['Config'])?['Env'],
        );
        for (final v in env) {
          if (v.startsWith('CRON_SCHEDULE=')) {
            final s = v.substring('CRON_SCHEDULE='.length).trim();
            if (CronSchedule.tryParse(s) != null) schedule = s;
          }
        }
      } on UpstreamException {
        // Keep the default schedule.
      }
    }
    RecyclarrRun? lastRun;
    try {
      final file = await newestRecyclarrLog(ctx.config.recyclarrLogDir);
      if (file != null) {
        lastRun = await readRecyclarrRun(file, redact: ctx.redact);
      }
    } on FileSystemException catch (err) {
      ctx.log.warning(
        'recyclarr logs are not readable: ${err.osError?.message ?? err.message}',
      );
    }
    return RecyclarrStatus(
      container: _stateOf(e),
      schedule: schedule,
      nextRunAt: CronSchedule.tryParse(schedule)
          ?.nextAfter(ctx.clock.now(), ctx.config.tzOffset),
      lastRun: lastRun,
      canSyncNow: await updaterServices() != null,
    );
  });

  /// Validates and starts `POST /maintenance/recyclarr/sync`.
  Future<JobRecord> startRecyclarrSync(ApiRequest req) async {
    _requireUpdater();
    await req.requireConfirm(
      'Runs `recyclarr sync` now: custom formats and quality profiles in Sonarr and Radarr are overwritten.',
    );
    return ctx.jobs.start(
      kind: 'maintenance.recyclarr.sync',
      target: 'recyclarr',
      userId: req.user.id,
      run: (h) async {
        h.step('Run recyclarr sync');
        final id = await _startUpdaterJob('/exec/recyclarr-sync');
        h.log('Updater job $id started');
        await UpdaterJobMirror(
          updater: _updater,
          handle: h,
          pollInterval: timings.updaterPollInterval,
          timeout: timings.updaterTimeout,
        ).follow(id, what: 'recyclarr sync');
        _recyclarr.invalidate(0);
        return {'state': 'synced'};
      },
    );
  }

  // -------------------------------------------------------------------------
  // Dashboard (API.md §11.8)
  // -------------------------------------------------------------------------

  Future<DashboardContribution> dashboard() async {
    _touchStats();
    final r = await _upstream(() => _card.get(0, _buildCard));
    final c = r.value;
    if (!r.stale) return c;
    final err = r.error;
    return DashboardContribution(
      data: c.data,
      alerts: c.alerts,
      stale: true,
      fetchedAt: r.fetchedAt,
      error: switch (err) {
        ApiException() => err.toApiError(''),
        UpstreamException() =>
          err.toApiException(resourceNotFound: false).toApiError(''),
        _ => null,
      },
    );
  }

  Future<DashboardContribution> _buildCard() async {
    final result = await _entriesResult();
    if (result.stale) throw result.error ?? ApiException.internal();
    final list = result.value;
    final now = ctx.clock.now();
    final scan = await lastScan();
    ContainersCardDecluttarr? declutter;
    try {
      final d = (await decluttarr()).value;
      declutter = ContainersCardDecluttarr(
        lastRunAt: d.lastRunAt,
        removed24h: d.last24h.removed.length,
      );
    } on Exception {
      declutter = null;
    }

    final names = {for (final e in list) e.name};
    final unhealthy = [
      for (final e in list)
        if (e.health == ContainerHealth.unhealthy) e.name,
    ]..sort();
    final stoppedEntries = [
      for (final e in list)
        if (e.state == ContainerState.exited || e.state == ContainerState.dead)
          e,
    ]..sort((a, b) => a.name.compareTo(b.name));
    final updatesAvailable = updates.all
        .where((r) => (r.updateAvailable ?? false) && names.contains(r.name))
        .length;
    final top = [
      for (final e in list)
        if (e.isRunning)
          if (stats.of(e.id) case final f?)
            ContainerCpuUsage(name: e.name, cpuPercent: f.cpuPercent),
    ]..sort((a, b) => b.cpuPercent.compareTo(a.cpuPercent));

    final card = ContainersCard(
      total: list.length,
      running: list.where((e) => e.isRunning).length,
      unhealthy: unhealthy,
      stopped: [for (final e in stoppedEntries) e.name],
      updatesAvailable: updatesAvailable,
      lastScan: scan,
      topCpu: top.take(3).toList(),
      decluttarr: declutter,
    );

    final dayAgo = now.subtract(const Duration(hours: 24));
    final alerts = <Alert>[
      for (final name in unhealthy)
        Alert(
          id: 'container.unhealthy.$name',
          severity: AlertSeverity.error,
          source: ServiceId.docker,
          feature: 'containers',
          title: '$name is unhealthy',
          message: 'Its healthcheck is failing.',
          route: '/containers/$name',
        ),
      for (final e in stoppedEntries)
        if ((e.exitCodeFromStatus ?? 0) != 0 ||
            (e.exitedAgo != null && e.exitedAgo! < const Duration(hours: 24)) ||
            events.since(dayAgo, name: e.name).isNotEmpty)
          Alert(
            id: 'container.stopped.${e.name}',
            severity: AlertSeverity.warning,
            source: ServiceId.docker,
            feature: 'containers',
            title: '${e.name} is stopped',
            message: e.statusText,
            route: '/containers/${e.name}',
            dismissible: true,
          ),
      if (updatesAvailable > 0)
        Alert(
          id: 'updates.available',
          severity: AlertSeverity.info,
          source: ServiceId.watchtower,
          feature: 'containers',
          title: updatesAvailable == 1
              ? '1 container update available'
              : '$updatesAvailable container updates available',
          route: '/containers/updates',
          dismissible: true,
        ),
    ];
    return DashboardContribution(data: card.toJson(), alerts: alerts);
  }
}
