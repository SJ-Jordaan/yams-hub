/// The Discord "indexers failing" alert (ARCHITECTURE §5.7.1): one message
/// when most enabled Prowlarr indexers have been failing for a while, one
/// when that recovers, nothing in between.
library;

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:yams_hub_gateway/src/core/feature_context.dart';
import 'package:yams_hub_gateway/src/core/notify/discord_webhook.dart';
import 'package:yams_models/yams_models.dart';

import 'prowlarr_mapping.dart';
import 'prowlarr_repository.dart';

/// How often the monitor looks at Prowlarr.
const indexerAlertInterval = Duration(minutes: 3);

/// A known sample further than this after the previous one (about two missed
/// intervals: Prowlarr unreachable, a stale snapshot, the hub stopped) restarts
/// the pending breach and recovery waits: time nobody observed is not
/// "continuously failing".
const indexerAlertMaxSampleGap = Duration(minutes: 7);

/// The ratio must stay below the threshold this long before "recovered".
const indexerAlertRecoverAfter = Duration(minutes: 5);

/// Below this many enabled indexers the rule does not apply.
const indexerAlertMinEnabled = 2;

/// The store file (under `$DATA`) holding the rule state across restarts.
const alertStateStoreName = 'alerts.json';

/// Names listed in one message.
const _maxNames = 10;

/// One look at Prowlarr: how many indexers are enabled and which of them are
/// failing (an `indexerstatus` row whose `disabledTill` is in the future).
final class IndexerFailureSample {
  const IndexerFailureSample({required this.enabled, required this.failing});

  final int enabled;

  /// Names of the failing enabled indexers.
  final List<String> failing;

  int get failingCount => failing.length;
}

/// The persisted state of the rule.
final class IndexerAlertState {
  IndexerAlertState({
    this.firing = false,
    this.breachSince,
    this.clearSince,
    this.firedAt,
    this.lastSampleAt,
  });

  factory IndexerAlertState.fromJson(Object? json) {
    final m = readMap(json);
    if (m == null) return IndexerAlertState();
    return IndexerAlertState(
      firing: readBool(m['firing']) ?? false,
      breachSince: readInstant(m['breachSince']),
      clearSince: readInstant(m['clearSince']),
      firedAt: readInstant(m['firedAt']),
      lastSampleAt: readInstant(m['lastSampleAt']),
    );
  }

  /// The "down" message was sent and "recovered" was not yet.
  bool firing;

  /// While not firing: first sample of the current run at or above the
  /// threshold.
  DateTime? breachSince;

  /// While firing: first sample of the current run below the threshold.
  DateTime? clearSince;

  /// When the "down" message was sent.
  DateTime? firedAt;

  /// When the last known sample was evaluated.
  DateTime? lastSampleAt;

  /// A breach or recovery wait is running (only then does [lastSampleAt]
  /// matter enough to persist on every sample).
  bool get pending => breachSince != null || clearSince != null;

  JsonMap toJson() => {
    'firing': firing,
    'breachSince': breachSince == null ? null : instantToJson(breachSince!),
    'clearSince': clearSince == null ? null : instantToJson(clearSince!),
    'firedAt': firedAt == null ? null : instantToJson(firedAt!),
    'lastSampleAt': lastSampleAt == null ? null : instantToJson(lastSampleAt!),
  };
}

/// What [IndexerAlertRule.evaluate] decided to announce.
sealed class IndexerAlertEvent {
  const IndexerAlertEvent(this.sample);

  final IndexerFailureSample sample;
}

/// The threshold has held for the whole duration.
final class IndexersDown extends IndexerAlertEvent {
  const IndexersDown(super.sample, {required this.failingFor});

  final Duration failingFor;
}

/// The ratio has stayed below the threshold for [indexerAlertRecoverAfter].
final class IndexersRecovered extends IndexerAlertEvent {
  const IndexersRecovered(super.sample, {this.downFor});

  /// Since the "down" message (null when unknown).
  final Duration? downFor;
}

/// The pure state machine. [evaluate] is called with each sample (null when
/// Prowlarr could not be read) and mutates [state].
final class IndexerAlertRule {
  IndexerAlertRule({
    required this.thresholdPercent,
    required this.failingFor,
    this.recoverAfter = indexerAlertRecoverAfter,
    this.minEnabled = indexerAlertMinEnabled,
    this.maxSampleGap = indexerAlertMaxSampleGap,
    IndexerAlertState? state,
  }) : state = state ?? IndexerAlertState();

  final double thresholdPercent;
  final Duration failingFor;
  final Duration recoverAfter;
  final int minEnabled;
  final Duration maxSampleGap;
  final IndexerAlertState state;

  /// Whether [s] is at or above the threshold.
  bool breaches(IndexerFailureSample s) =>
      s.failingCount * 100 >= thresholdPercent * s.enabled;

  /// Advances the state with [sample] taken at [now]; returns the message to
  /// send, if any.
  ///
  /// - Unknown data (null) changes nothing: Prowlarr being down is Uptime
  ///   Kuma's alert, and a sent alert stays sent.
  /// - A known sample more than [maxSampleGap] after the previous one (or
  ///   before it: the clock went back) restarts a pending breach or recovery
  ///   at [now]: only observed time counts as continuous. The firing state is
  ///   kept, so nothing is sent twice.
  /// - Fewer than [minEnabled] enabled indexers: the rule does not apply; a
  ///   pending breach or recovery starts over, a sent alert stays sent.
  IndexerAlertEvent? evaluate(IndexerFailureSample? sample, DateTime now) {
    if (sample == null) return null;
    final last = state.lastSampleAt;
    state.lastSampleAt = now;
    if (last != null &&
        (now.isBefore(last) || now.difference(last) > maxSampleGap)) {
      state
        ..breachSince = null
        ..clearSince = null;
    }
    if (sample.enabled < minEnabled) {
      state
        ..breachSince = null
        ..clearSince = null;
      return null;
    }
    final breach = breaches(sample);
    if (!state.firing) {
      if (!breach) {
        state.breachSince = null;
        return null;
      }
      final since = state.breachSince ??= now;
      final held = now.difference(since);
      if (held < failingFor) return null;
      state
        ..firing = true
        ..breachSince = null
        ..clearSince = null
        ..firedAt = now;
      return IndexersDown(sample, failingFor: held);
    }
    if (breach) {
      state.clearSince = null;
      return null;
    }
    final since = state.clearSince ??= now;
    if (now.difference(since) < recoverAfter) return null;
    final firedAt = state.firedAt;
    state
      ..firing = false
      ..breachSince = null
      ..clearSince = null
      ..firedAt = null;
    return IndexersRecovered(
      sample,
      downFor: firedAt == null ? null : now.difference(firedAt),
    );
  }
}

/// Reads [repo]'s cached snapshot as a sample; null when Prowlarr is
/// unreachable or only a stale copy is left (unknown, not "recovered").
Future<IndexerFailureSample?> sampleProwlarr(
  ProwlarrRepository repo,
  Clock clock, {
  Logger? log,
}) async {
  final CacheResult<ProwlarrSnapshot> snap;
  try {
    snap = await repo.snapshot();
  } on Object catch (e) {
    log?.fine('indexer alert: Prowlarr unavailable (${e.runtimeType})');
    return null;
  }
  if (snap.stale) return null;
  final now = clock.now();
  var enabled = 0;
  final failing = <String>[];
  for (final raw in snap.value.indexers) {
    final id = readInt(raw['id']);
    if (id == null || readBool(raw['enable']) != true) continue;
    enabled++;
    if (snap.value.statuses[id]?.isFailingAt(now) ?? false) {
      failing.add(readString(raw['name']) ?? '#$id');
    }
  }
  failing.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return IndexerFailureSample(enabled: enabled, failing: failing);
}

/// The Discord payload for [event]. [indexersPage] is the hub's indexers
/// screen (null when no public URL is configured).
Map<String, Object?> discordMessage(
  IndexerAlertEvent event, {
  Uri? indexersPage,
}) {
  final s = event.sample;
  final String title;
  final int color;
  switch (event) {
    case IndexersDown(:final failingFor):
      title =
          '⚠️ Indexers down: ${s.failingCount} of ${s.enabled} failing for '
          '${_minutes(failingFor)}';
      color = 0xE67E22;
    case IndexersRecovered():
      title = '✅ Indexers recovered: ${s.failingCount} of ${s.enabled} failing';
      color = 0x2ECC71;
  }
  final names = s.failing.take(_maxNames).map(_plain).toList();
  final more = s.failingCount - names.length;
  final description = [
    if (names.isNotEmpty)
      'Failing: ${names.join(', ')}${more > 0 ? ' and $more more' : ''}',
  ].join('\n');
  return {
    'username': 'YAMS Hub',
    // Indexer names never ping anyone.
    'allowed_mentions': {'parse': <String>[]},
    'embeds': [
      {
        'title': title,
        if (description.isNotEmpty) 'description': description,
        if (indexersPage != null) 'url': indexersPage.toString(),
        'color': color,
      },
    ],
  };
}

String _minutes(Duration d) {
  final m = d.inMinutes;
  if (m < 120) return '$m min';
  final h = d.inHours;
  return h < 48 ? '$h h' : '${d.inDays} days';
}

/// An indexer name without Discord markdown or mention syntax.
String _plain(String name) {
  final clean = name.replaceAll(RegExp(r'[*_`~|>@#<\[\]()\\]'), '').trim();
  final short = clean.length > 60 ? '${clean.substring(0, 57)}...' : clean;
  return short.isEmpty ? '?' : short;
}

/// The hub's indexers screen under the first `publicUrls` entry.
Uri? indexersPageUrl(List<Uri> publicUrls) {
  if (publicUrls.isEmpty) return null;
  final base = publicUrls.first;
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    pathSegments: [...base.pathSegments.where((s) => s.isNotEmpty), 'indexers'],
  );
}

/// Runs the rule every [interval]: samples Prowlarr, persists the state when
/// it changes and posts the messages.
final class IndexerAlertMonitor {
  IndexerAlertMonitor({
    required this.rule,
    required this.store,
    required this.sample,
    required this.webhook,
    required this.clock,
    this.indexersPage,
    Logger? log,
  }) : _log = log ?? Logger('feature.indexers.alert');

  /// Builds the rule from the policy and the state persisted in [store].
  factory IndexerAlertMonitor.create({
    required AlertThresholds thresholds,
    required JsonFileStore store,
    required Future<IndexerFailureSample?> Function() sample,
    required DiscordWebhook webhook,
    required Clock clock,
    Uri? indexersPage,
    Logger? log,
  }) {
    final doc = readMap(store.read());
    return IndexerAlertMonitor(
      rule: IndexerAlertRule(
        thresholdPercent: thresholds.indexersFailingPercent,
        failingFor: Duration(minutes: thresholds.indexersFailingForMinutes),
        state: IndexerAlertState.fromJson(doc?['indexersFailing']),
      ),
      store: store,
      sample: sample,
      webhook: webhook,
      clock: clock,
      indexersPage: indexersPage,
      log: log,
    );
  }

  final IndexerAlertRule rule;
  final JsonFileStore store;
  final Future<IndexerFailureSample?> Function() sample;
  final DiscordWebhook webhook;
  final Clock clock;
  final Uri? indexersPage;
  final Logger _log;

  Timer? _timer;
  Future<void>? _running;

  /// Evaluates every [interval] until [stop].
  void start({Duration interval = indexerAlertInterval}) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(tick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One evaluation (overlapping calls share the running one). Never throws.
  Future<void> tick() =>
      _running ??= _tick().whenComplete(() => _running = null);

  Future<void> _tick() async {
    try {
      final s = await sample();
      final state = rule.state;
      final before = state.toJson();
      final event = rule.evaluate(s, clock.now());
      final after = state.toJson();
      // lastSampleAt changes on every known sample; it is only written while
      // a wait is running (a restart must see a gap in it), not every 3 min.
      final changed = after.keys.any(
        (k) => before[k] != after[k] && (k != 'lastSampleAt' || state.pending),
      );
      if (changed) {
        // The state is saved before the message goes out: a crash in
        // between loses one message instead of repeating it.
        await _save();
      }
      if (event == null) return;
      final down = event is IndexersDown;
      _log.info(
        down
            ? 'indexers down: ${event.sample.failingCount} of '
                  '${event.sample.enabled} failing; sending a Discord alert'
            : 'indexers recovered: ${event.sample.failingCount} of '
                  '${event.sample.enabled} failing; sending a Discord alert',
      );
      // A message that cannot be delivered is dropped (logged by the
      // webhook): the rule never repeats one.
      await webhook.send(discordMessage(event, indexersPage: indexersPage));
    } on Object catch (e, st) {
      _log.warning('indexer alert evaluation failed', e, st);
    }
  }

  Future<void> _save() async {
    final doc = Map<String, Object?>.of(readMap(store.read()) ?? const {});
    doc['version'] = 1;
    doc['indexersFailing'] = rule.state.toJson();
    try {
      await store.writeNow(doc);
    } on Object {
      // Logged by the store; the in-memory state still holds.
    }
  }
}
