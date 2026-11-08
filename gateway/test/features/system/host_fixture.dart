/// Builds fake host trees (procfs files, `HOST_NET_DEV`, a sysfs with
/// symlinked hwmon entries) from `fixtures/system/host_proc_sys_snapshot.json`
/// and the synthetic samples in `data/`.
///
/// Synthetic samples (ARCHITECTURE §5.19):
/// - `proc_diskstats_t{0,1}.synthetic.txt`: `/proc/diskstats` was not captured.
///   Devices follow integrations/system.md §4 (`dm-0` = volume1, `sda`/`sdb` =
///   the RAID0 disks, `mmcblk0` = eMMC). t1 is 5 s after t0: `dm-0` +1,000
///   sectors read and +48,828 written (102,400 B/s and 4,999,987 B/s).
/// - `uptimekuma_heartbeat_down.synthetic.json`: the heartbeat fixture's shape
///   with monitor 14 (gluetun) ending on DOWN beats.
/// - `uptimekuma_status_page_incident.synthetic.json`: a status page with a
///   pinned incident (`incident` object) and groups out of weight order.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yams_hub_gateway/src/features/system/host/host_sampler.dart';
import 'package:yams_hub_gateway/src/features/system/host/statvfs.dart';
import 'package:yams_hub_gateway/src/features/system/system_module.dart';

import '../../support/test_hub.dart';

/// The raw snapshot (`fixtures/system/host_proc_sys_snapshot.json`).
JsonMap hostSnapshot() =>
    fixture('system/host_proc_sys_snapshot.json')! as JsonMap;

/// A synthetic sample of this test directory.
String systemData(String name) {
  for (final base in [
    'test/features/system/data',
    'gateway/test/features/system/data',
  ]) {
    final f = File(p.join(base, name));
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw StateError(
    'synthetic sample $name not found from ${Directory.current.path}',
  );
}

/// Zenith's `/volume1` (df -Pk: 7719270092 blocks, 3765233148 used,
/// 3954020560 available).
const zenithVolume = FsUsage(
  totalBytes: 7719270092 * 1024,
  freeBytes: (7719270092 - 3765233148) * 1024,
  availableBytes: 3954020560 * 1024,
);

/// Byte deltas applied to the host `net/dev` at t1 (5 s after t0):
/// eth0 120,000 B/s down and 2,400,000 B/s up; tailscale0 2,000 B/s each way.
const eth0RxDelta = 600000;
const eth0TxDelta = 12000000;
const tailscaleDelta = 10000;

/// Writes the procfs files of the snapshot into [procDir] and the host
/// network counters into [netDev]. [t1] uses the second `/proc/stat` and
/// advances the network and disk counters.
void writeProcSnapshot(
  String procDir, {
  String? netDev,
  bool t1 = false,
  bool withNet = true,
}) {
  final s = hostSnapshot();
  Directory(procDir).createSync(recursive: true);
  void put(String name, String text) =>
      File(p.join(procDir, name)).writeAsStringSync(text);
  put('stat', s[t1 ? 'proc_stat_t1' : 'proc_stat_t0']! as String);
  put('meminfo', s['proc_meminfo']! as String);
  put('loadavg', s['proc_loadavg']! as String);
  put('uptime', s['proc_uptime']! as String);
  put('cpuinfo', 'processor\t: 0\n${s['proc_cpuinfo_model']}\n');
  put('mdstat', s['proc_mdstat']! as String);
  put(
    'diskstats',
    systemData(
      t1
          ? 'proc_diskstats_t1.synthetic.txt'
          : 'proc_diskstats_t0.synthetic.txt',
    ),
  );
  if (netDev != null) {
    final f = File(netDev);
    if (!withNet) {
      if (f.existsSync()) f.deleteSync();
      return;
    }
    var text = s['host_proc_1_net_dev']! as String;
    if (t1) text = _advanceNet(text);
    f.writeAsStringSync(text);
  }
}

String _advanceNet(String text) {
  final out = <String>[];
  for (final line in text.split('\n')) {
    final i = line.indexOf(':');
    if (i <= 0 || line.contains('|')) {
      out.add(line);
      continue;
    }
    final name = line.substring(0, i).trim();
    final cols = line.substring(i + 1).trim().split(RegExp(r'\s+'));
    final (rx, tx) = switch (name) {
      'eth0' => (eth0RxDelta, eth0TxDelta),
      'tailscale0' => (tailscaleDelta, tailscaleDelta),
      _ => (0, 0),
    };
    cols[0] = '${int.parse(cols[0]) + rx}';
    cols[8] = '${int.parse(cols[8]) + tx}';
    out.add('$name: ${cols.join(' ')}');
  }
  return out.join('\n');
}

/// Builds `<sysDir>/class/hwmon` like Zenith's: `hwmon0` (acpitz) and
/// `hwmon1` (coretemp) are relative symlinks into `devices/`, plus a dangling
/// `hwmon2`. With [coretemp] false the coretemp device is left out.
void writeHwmonTree(
  String sysDir, {
  bool coretemp = true,
  bool dangling = true,
}) {
  final snapshot = (hostSnapshot()['sys_class_hwmon']! as JsonMap);
  final classDir = Directory(p.join(sysDir, 'class', 'hwmon'))
    ..createSync(recursive: true);
  void device(String rel, JsonMap spec) {
    final dir = Directory(p.join(sysDir, rel))..createSync(recursive: true);
    File(p.join(dir.path, 'name')).writeAsStringSync('${spec['name']}\n');
    for (final e in (spec['temps']! as JsonMap).entries) {
      File(p.join(dir.path, e.key)).writeAsStringSync('${e.value}\n');
    }
  }

  void link(String name, String target) {
    final l = Link(p.join(classDir.path, name));
    if (l.existsSync()) l.deleteSync();
    l.createSync(target);
  }

  device(
    'devices/virtual/thermal/thermal_zone0/hwmon0',
    snapshot['hwmon0']! as JsonMap,
  );
  link('hwmon0', '../../devices/virtual/thermal/thermal_zone0/hwmon0');
  if (coretemp) {
    device(
      'devices/platform/coretemp.0/hwmon/hwmon1',
      snapshot['hwmon1']! as JsonMap,
    );
    link('hwmon1', '../../devices/platform/coretemp.0/hwmon/hwmon1');
  }
  if (dangling) link('hwmon2', '../../devices/platform/gone.0/hwmon/hwmon2');
}

/// A [TestHub] whose system module reads [usage] instead of the real
/// `statvfs` of the temp data dir.
TestHub systemTestHub({
  FsUsage? usage = zenithVolume,
  Set<ServiceId> unconfigured = const {},
  String? policyYaml,
  Set<String>? startOnly,
  FakeUpstreams? fakes,
}) => TestHub(
  unconfigured: unconfigured,
  policyYaml: policyYaml,
  startOnly: startOnly,
  fakes: fakes,
  modules: (ctx) => [
    for (final m in buildFeatureModules(ctx))
      if (m.id == 'system')
        systemModuleWith(ctx.forFeature('system'), usage)
      else
        m,
  ],
);

SystemModule systemModuleWith(FeatureContext ctx, FsUsage? usage) =>
    SystemModule(
      ctx,
      sampler: HostSampler(
        procDir: ctx.config.procDir,
        sysDir: ctx.config.hostSys,
        netDevPath: ctx.config.hostNetDev,
        volumePath: ctx.config.dataDir,
        clock: ctx.clock,
        fsUsage: (_) => usage,
      ),
    );

/// The system module of [hub].
SystemModule systemModuleOf(TestHub hub) =>
    hub.hub.modules.whereType<SystemModule>().single;

/// Writes the t0 snapshot (and the hwmon tree) into the hub's host dirs.
void writeHubHost(
  TestHub hub, {
  bool t1 = false,
  bool withNet = true,
  bool hwmon = true,
}) {
  writeProcSnapshot(
    hub.config.procDir,
    netDev: hub.config.hostNetDev,
    t1: t1,
    withNet: withNet,
  );
  if (hwmon && !t1) writeHwmonTree(hub.config.hostSys);
}
