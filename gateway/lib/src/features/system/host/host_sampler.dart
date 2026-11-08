/// The always-on host metrics sampler (API.md §13.1, integrations/system.md
/// §4): every 5 s it reads the host-global procfs files from the container's
/// own `/proc`, the host NIC counters from `HOST_NET_DEV`, coretemp from
/// `HOST_SYS` and `statvfs` of the data volume, and records the values in
/// [MetricHistory].
library;

import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:yams_hub_gateway/src/core/clock.dart';
import 'package:yams_models/yams_models.dart';

import 'hwmon.dart';
import 'metric_history.dart';
import 'proc_parsers.dart';
import 'statvfs.dart';

/// The host interface carrying remote (tailnet) traffic.
const tailscaleInterface = 'tailscale0';

final class HostSampler {
  HostSampler({
    required this.procDir,
    required this.sysDir,
    required this.netDevPath,
    required this.volumePath,
    required this.clock,
    this.volumeMount = '/volume1',
    this.diskDevice = 'dm-0',
    this.interval = const Duration(seconds: 5),
    this._fsUsage = statvfsUsage,
    Logger? log,
  }) : _log = log ?? Logger('feature.system.sampler'),
       _hwmon = HwmonReader(sysDir),
       history = MetricHistory(sampleInterval: interval);

  /// The container's own `/proc` (host-global files).
  final String procDir;

  /// `HOST_SYS`.
  final String sysDir;

  /// `HOST_NET_DEV` (the host's `/proc/1/net/dev`).
  final String netDevPath;

  /// A path on the data volume for `statvfs` (`/data`).
  final String volumePath;

  /// The host mount [volumePath] lives on, as reported to clients.
  final String volumeMount;

  /// The `/proc/diskstats` device of the data volume.
  final String diskDevice;
  final Duration interval;
  final Clock clock;
  final MetricHistory history;

  final FsUsageReader _fsUsage;
  final Logger _log;
  final HwmonReader _hwmon;

  /// The host's name (from Docker `/info`), set by the module when known.
  String? hostname;

  Timer? _timer;
  Future<HostMetrics>? _inflight;
  HostMetrics? _latest;
  final _reported = <String>{};

  // Previous counters for rates.
  DateTime? _prevAt;
  ProcStat? _prevStat;
  Map<String, NetCounters> _prevNet = const {};
  DiskCounters? _prevDisk;

  /// The newest sample, if any.
  HostMetrics? get latest => _latest;

  bool get running => _timer != null;

  /// Takes a first sample and then one every [interval].
  Future<void> start() async {
    if (_timer != null) return;
    await _sampleSafely();
    _timer = Timer.periodic(interval, (_) => unawaited(_sampleSafely()));
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final inflight = _inflight;
    if (inflight != null) {
      try {
        await inflight;
      } catch (_) {
        // Already logged by _sampleSafely.
      }
    }
  }

  /// The newest sample when it is younger than two intervals; otherwise a
  /// new one (the sampler is not running, e.g. in tests, or has stalled).
  Future<HostMetrics> current() {
    final l = _latest;
    if (l != null && clock.now().difference(l.sampledAt) < interval * 2) {
      return Future.value(l);
    }
    return sample();
  }

  /// Reads every source once, updates the rates and the history. Concurrent
  /// callers share one read.
  Future<HostMetrics> sample() =>
      _inflight ??= _sample().whenComplete(() => _inflight = null);

  Future<void> _sampleSafely() async {
    try {
      await sample();
    } catch (e, st) {
      _log.warning('host sample failed', e, st);
    }
  }

  Future<HostMetrics> _sample() async {
    final now = clock.now();
    final texts = await Future.wait([
      _read(p.join(procDir, 'stat')),
      _read(p.join(procDir, 'meminfo')),
      _read(p.join(procDir, 'loadavg')),
      _read(p.join(procDir, 'uptime')),
      _read(p.join(procDir, 'cpuinfo')),
      _read(p.join(procDir, 'mdstat')),
      _read(p.join(procDir, 'diskstats')),
      _read(netDevPath),
    ]);
    final [
      statText,
      memText,
      loadText,
      uptimeText,
      cpuinfoText,
      mdText,
      diskText,
      netText,
    ] = texts;

    final dt = _prevAt == null
        ? null
        : now.difference(_prevAt!).inMilliseconds / 1000;
    final hasDelta = dt != null && dt > 0;

    // CPU.
    final stat = statText == null ? null : ProcStat.parse(statText);
    double? percent;
    var perCore = const <double>[];
    final prevStat = _prevStat;
    if (stat != null && prevStat != null && hasDelta) {
      percent = stat.total.percentSince(prevStat.total);
      if (stat.cores.length == prevStat.cores.length) {
        perCore = [
          for (var i = 0; i < stat.cores.length; i++)
            _round1(stat.cores[i].percentSince(prevStat.cores[i]) ?? 0),
        ];
      }
    }
    final load = loadText == null ? null : parseLoadAvg(loadText);
    final temps = _hwmon.read();
    final model = cpuinfoText == null ? null : parseCpuModel(cpuinfoText);
    final cores = (stat?.cores.isEmpty ?? true)
        ? (cpuinfoText == null ? null : _countProcessors(cpuinfoText))
        : stat!.cores.length;
    final HostCpu? cpu =
        stat == null && load == null && model == null && temps == null
        ? null
        : HostCpu(
            model: model,
            cores: cores,
            percent: percent == null ? null : _round1(percent),
            perCorePercent: perCore,
            load1: load?[0],
            load5: load?[1],
            load15: load?[2],
            packageTempC: temps?.packageC,
            coreTempsC: temps?.coresC ?? const [],
          );

    // Memory.
    final mem = memText == null ? null : MemInfo.parse(memText);
    final memory = mem == null
        ? null
        : HostMemory(
            totalBytes: mem.totalBytes,
            usedBytes: mem.usedBytes,
            availableBytes: mem.availableBytes,
            swapTotalBytes: mem.swapTotalBytes,
            swapUsedBytes: mem.swapUsedBytes,
          );

    // Storage.
    final usage = _safeUsage();
    final storage = usage == null || usage.totalBytes <= 0
        ? const <HostStorage>[]
        : [
            HostStorage(
              mount: volumeMount,
              totalBytes: usage.totalBytes,
              usedBytes: usage.usedBytes,
              freeBytes: usage.availableBytes,
              usedPercent: _round1(usage.usedPercent),
            ),
          ];

    // RAID.
    final raid = mdText == null
        ? const <HostRaid>[]
        : [
            for (final a in parseMdstat(mdText))
              HostRaid(
                device: a.device,
                level: a.level,
                state: a.state,
                members: a.members,
                redundant: a.redundant,
                healthy: a.healthy,
              ),
          ];

    // Disk I/O.
    final disk = diskText == null ? null : parseDiskstats(diskText, diskDevice);
    HostDiskIo? diskIo;
    final prevDisk = _prevDisk;
    if (disk != null && prevDisk != null && hasDelta) {
      diskIo = HostDiskIo(
        readBps: _rate(disk.readBytes, prevDisk.readBytes, dt),
        writeBps: _rate(disk.writtenBytes, prevDisk.writtenBytes, dt),
      );
    }

    // Network.
    final counters = netText == null
        ? const <NetCounters>[]
        : [
            for (final c in parseNetDev(netText))
              if (isHostInterface(c.interfaceName)) c,
          ];
    final network = [
      for (final c in counters)
        HostNetwork(
          interfaceName: c.interfaceName,
          rxBps: switch (_prevNet[c.interfaceName]) {
            final prev? when hasDelta => _rate(c.rxBytes, prev.rxBytes, dt),
            _ => 0,
          },
          txBps: switch (_prevNet[c.interfaceName]) {
            final prev? when hasDelta => _rate(c.txBytes, prev.txBytes, dt),
            _ => 0,
          },
          rxTotalBytes: c.rxBytes,
          txTotalBytes: c.txBytes,
        ),
    ];
    final hostNetwork = netText != null && counters.isNotEmpty;

    _note('stat', stat != null, 'cannot read ${p.join(procDir, 'stat')}');
    _note('meminfo', mem != null, 'cannot read ${p.join(procDir, 'meminfo')}');
    _note('netdev', hostNetwork, 'host network counters missing ($netDevPath)');
    _note('coretemp', temps != null, 'no coretemp sensor under $sysDir');
    _note('statvfs', storage.isNotEmpty, 'statvfs($volumePath) unavailable');

    final metrics = HostMetrics(
      hostname: hostname,
      cpu: cpu,
      memory: memory,
      uptimeSeconds: uptimeText == null ? null : parseUptime(uptimeText),
      storage: storage,
      raid: raid,
      network: hostNetwork ? network : const [],
      diskIo: diskIo,
      sampledAt: now,
      sources: HostSources(
        temperature: temps != null,
        hostNetwork: hostNetwork,
      ),
    );

    final primary = primaryInterface(metrics);
    history.add(now, {
      HostMetricKind.cpu: ?cpu?.percent,
      HostMetricKind.memory: ?memory?.usedBytes.toDouble(),
      HostMetricKind.temperature: ?temps?.packageC,
      if (hasDelta && primary != null) ...{
        HostMetricKind.netRx: primary.rxBps.toDouble(),
        HostMetricKind.netTx: primary.txBps.toDouble(),
      },
      if (diskIo != null) ...{
        HostMetricKind.diskRead: diskIo.readBps.toDouble(),
        HostMetricKind.diskWrite: diskIo.writeBps.toDouble(),
      },
    });

    _prevAt = now;
    _prevStat = stat ?? _prevStat;
    _prevNet = {for (final c in counters) c.interfaceName: c};
    _prevDisk = disk;
    return _latest = metrics;
  }

  /// The LAN interface whose traffic the history and the dashboard report:
  /// `eth0` when present, else the first host interface that is not the
  /// tailnet (whose bytes also cross the LAN interface).
  static HostNetwork? primaryInterface(HostMetrics m) {
    final eth0 = m.interfaceNamed('eth0');
    if (eth0 != null) return eth0;
    for (final n in m.network) {
      if (n.interfaceName != tailscaleInterface) return n;
    }
    return null;
  }

  FsUsage? _safeUsage() {
    try {
      return _fsUsage(volumePath);
    } catch (e) {
      return null;
    }
  }

  void _note(String source, bool ok, String message) {
    if (ok) {
      if (_reported.remove(source)) _log.info('$source available again');
    } else if (_reported.add(source)) {
      _log.info(message);
    }
  }

  static Future<String?> _read(String path) async {
    try {
      return await File(path).readAsString();
    } on FileSystemException {
      return null;
    }
  }

  static int? _countProcessors(String cpuinfo) {
    final n = RegExp(
      r'^processor\s*:',
      multiLine: true,
    ).allMatches(cpuinfo).length;
    return n == 0 ? null : n;
  }

  static int _rate(int current, int previous, double? seconds) {
    if (seconds == null || seconds <= 0 || current < previous) return 0;
    return ((current - previous) / seconds).round();
  }

  static double _round1(double v) => (v * 10).roundToDouble() / 10;
}
