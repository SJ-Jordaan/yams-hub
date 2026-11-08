/// The optional YAML policy file `yams-hub.yaml` (ARCHITECTURE §5.2.1).
library;

import 'package:yaml/yaml.dart';
import 'package:yams_models/yams_models.dart';

/// Container guardrails and display groups.
final class ContainerPolicy {
  const ContainerPolicy({
    this.locked = const ['yams-hub', 'socket-proxy-hub', 'yams-hub-updater'],
    this.confirm = const [
      'gluetun',
      'jellyfin',
      'portainer',
      'socket-proxy',
      'jellystat-db',
      'qbittorrent',
    ],
    this.groups = const {
      'media': [
        'jellyfin',
        'seerr',
        'shelfmark',
        'audiobookshelf',
        'kavita',
        'jellystat',
        'jellystat-db',
      ],
      'automation': [
        'sonarr',
        'radarr',
        'bazarr',
        'prowlarr',
        'flaresolverr',
        'recyclarr',
        'decluttarr',
      ],
      'downloads': ['gluetun', 'qbittorrent'],
      'system': [
        'homepage',
        'portainer',
        'watchtower',
        'socket-proxy',
        'socket-proxy-hub',
        'yams-hub',
        'yams-hub-updater',
        'uptime-kuma',
      ],
    },
  });

  /// Never stopped, restarted or updated from the hub.
  final List<String> locked;

  /// Actions need `confirm=true`.
  final List<String> confirm;

  /// Display grouping: group name to container names.
  final Map<String, List<String>> groups;

  bool isLocked(String name) => locked.contains(name);
  bool needsConfirm(String name) => confirm.contains(name);

  /// The group [name] belongs to, or null.
  String? groupOf(String name) {
    for (final e in groups.entries) {
      if (e.value.contains(name)) return e.key;
    }
    return null;
  }
}

/// `policy:` switches.
final class HubPolicy {
  const HubPolicy({
    this.allowGlobalSearch = false,
    this.allowArrDeleteFiles = true,
    this.containers = const ContainerPolicy(),
  });

  final bool allowGlobalSearch;
  final bool allowArrDeleteFiles;
  final ContainerPolicy containers;
}

/// `alerts:` thresholds.
final class AlertThresholds {
  const AlertThresholds({
    this.cpuTempWarnC = 85,
    this.volumeUsedWarnPercent = 90,
  });

  final double cpuTempWarnC;
  final double volumeUsedWarnPercent;
}

/// `auth:` settings.
final class AuthSettings {
  const AuthSettings({
    this.accessTokenTtlMinutes = 60,
    this.refreshTokenTtlDays = 90,
    this.adminRefreshTokenTtlDays = 30,
    this.pbkdf2Iterations = 600000,
  });

  final int accessTokenTtlMinutes;
  final int refreshTokenTtlDays;
  final int adminRefreshTokenTtlDays;
  final int pbkdf2Iterations;

  Duration get accessTokenTtl => Duration(minutes: accessTokenTtlMinutes);

  /// Refresh token lifetime for [role] (admins get the shorter one).
  Duration refreshTokenTtl(Role role) => Duration(
    days: role == Role.admin ? adminRefreshTokenTtlDays : refreshTokenTtlDays,
  );
}

/// `imageCache:` limits.
final class ImageCacheSettings {
  const ImageCacheSettings({
    this.maxBytes = 1073741824,
    this.newRemoteEntriesPerUserPerMinute = 300,
  });

  final int maxBytes;
  final int newRemoteEntriesPerUserPerMinute;
}

/// The default web UI ports (ARCHITECTURE §5.2.1).
const defaultExternalAppPorts = <ExternalApp, int>{
  ExternalApp.jellyfin: 8096,
  ExternalApp.audiobookshelf: 13378,
  ExternalApp.kavita: 5000,
  ExternalApp.seerr: 5055,
  ExternalApp.shelfmark: 8084,
  ExternalApp.sonarr: 8989,
  ExternalApp.radarr: 7878,
  ExternalApp.prowlarr: 9696,
  ExternalApp.bazarr: 6767,
  ExternalApp.qbittorrent: 8081,
  ExternalApp.uptimeKuma: 3001,
  ExternalApp.jellystat: 3002,
  ExternalApp.portainer: 9000,
};

const defaultRemoteImageHosts = [
  'artworks.thetvdb.com',
  'image.tmdb.org',
  'assets.fanart.tv',
  'static.tvmaze.com',
  'www.gravatar.com',
];

/// Everything the policy file can set. All keys are optional; the defaults
/// are the values of ARCHITECTURE §5.2.1.
final class PolicyConfig {
  PolicyConfig({
    this.publicUrls = const [],
    Map<ExternalApp, ExternalAppConfig>? externalApps,
    this.policy = const HubPolicy(),
    this.alerts = const AlertThresholds(),
    this.auth = const AuthSettings(),
    this.imageCache = const ImageCacheSettings(),
    this.remoteImageHosts = defaultRemoteImageHosts,
  }) : externalApps =
           externalApps ??
           {
             for (final e in defaultExternalAppPorts.entries)
               e.key: ExternalAppConfig(port: e.value),
           };

  final List<Uri> publicUrls;
  final Map<ExternalApp, ExternalAppConfig> externalApps;
  final HubPolicy policy;
  final AlertThresholds alerts;
  final AuthSettings auth;
  final ImageCacheSettings imageCache;
  final List<String> remoteImageHosts;

  /// Parses the YAML document [source]. Problems are appended to [errors]
  /// (one message per bad key); the defaults are used for those keys.
  static PolicyConfig parse(String source, List<String> errors) {
    final Object? doc;
    try {
      doc = loadYaml(source);
    } on YamlException catch (e) {
      errors.add(
        'policy file is not valid YAML (line ${e.span?.start.line == null ? '?' : e.span!.start.line + 1})',
      );
      return PolicyConfig();
    }
    if (doc == null) return PolicyConfig();
    if (doc is! Map) {
      errors.add('policy file must be a YAML mapping');
      return PolicyConfig();
    }
    final r = _Reader(errors);
    final root = doc;
    r.checkKeys(root, '', const {
      'publicUrls',
      'externalApps',
      'policy',
      'alerts',
      'auth',
      'imageCache',
      'remoteImageHosts',
    });

    final publicUrls = <Uri>[];
    for (final s in r.stringList(root, 'publicUrls') ?? const <String>[]) {
      final u = Uri.tryParse(s);
      if (u == null ||
          !(u.scheme == 'http' || u.scheme == 'https') ||
          u.host.isEmpty) {
        errors.add('publicUrls: "$s" is not an http(s) URL');
      } else {
        publicUrls.add(u);
      }
    }

    final externalApps = <ExternalApp, ExternalAppConfig>{
      for (final e in defaultExternalAppPorts.entries)
        e.key: ExternalAppConfig(port: e.value),
    };
    final apps = r.map(root, 'externalApps');
    if (apps != null) {
      for (final e in apps.entries) {
        final key = '${e.key}';
        final app = ExternalApp.fromJson(key);
        if (app == ExternalApp.unknown) {
          errors.add('externalApps.$key: unknown app');
          continue;
        }
        final v = e.value;
        if (v is! Map) {
          errors.add('externalApps.$key must be a mapping');
          continue;
        }
        r.checkKeys(v, 'externalApps.$key.', const {'port', 'baseUrl'});
        final port =
            r.integer(v, 'port', 'externalApps.$key.', min: 1, max: 65535) ??
            externalApps[app]!.port;
        String? baseUrl = r.string(v, 'baseUrl', 'externalApps.$key.');
        if (baseUrl != null) {
          final u = Uri.tryParse(baseUrl);
          if (u == null ||
              !(u.scheme == 'http' || u.scheme == 'https') ||
              u.host.isEmpty) {
            errors.add('externalApps.$key.baseUrl is not an http(s) URL');
            baseUrl = null;
          }
        }
        externalApps[app] = ExternalAppConfig(port: port, baseUrl: baseUrl);
      }
    }

    var policy = const HubPolicy();
    final pol = r.map(root, 'policy');
    if (pol != null) {
      r.checkKeys(pol, 'policy.', const {
        'allowGlobalSearch',
        'allowArrDeleteFiles',
        'containers',
      });
      var containers = const ContainerPolicy();
      final c = r.map(pol, 'containers', 'policy.');
      if (c != null) {
        r.checkKeys(c, 'policy.containers.', const {
          'locked',
          'confirm',
          'groups',
        });
        const d = ContainerPolicy();
        final groups = <String, List<String>>{};
        final g = r.map(c, 'groups', 'policy.containers.');
        if (g != null) {
          for (final e in g.entries) {
            groups['${e.key}'] =
                r.stringList(g, '${e.key}', 'policy.containers.groups.') ??
                const [];
          }
        }
        containers = ContainerPolicy(
          locked: r.stringList(c, 'locked', 'policy.containers.') ?? d.locked,
          confirm:
              r.stringList(c, 'confirm', 'policy.containers.') ?? d.confirm,
          groups: g == null ? d.groups : groups,
        );
      }
      policy = HubPolicy(
        allowGlobalSearch:
            r.boolean(pol, 'allowGlobalSearch', 'policy.') ?? false,
        allowArrDeleteFiles:
            r.boolean(pol, 'allowArrDeleteFiles', 'policy.') ?? true,
        containers: containers,
      );
    }

    var alerts = const AlertThresholds();
    final a = r.map(root, 'alerts');
    if (a != null) {
      r.checkKeys(a, 'alerts.', const {
        'cpuTempWarnC',
        'volumeUsedWarnPercent',
      });
      alerts = AlertThresholds(
        cpuTempWarnC:
            r.number(a, 'cpuTempWarnC', 'alerts.', min: 30, max: 120) ?? 85,
        volumeUsedWarnPercent:
            r.number(a, 'volumeUsedWarnPercent', 'alerts.', min: 1, max: 100) ??
            90,
      );
    }

    var auth = const AuthSettings();
    final au = r.map(root, 'auth');
    if (au != null) {
      r.checkKeys(au, 'auth.', const {
        'accessTokenTtlMinutes',
        'refreshTokenTtlDays',
        'adminRefreshTokenTtlDays',
        'pbkdf2Iterations',
      });
      auth = AuthSettings(
        accessTokenTtlMinutes:
            r.integer(
              au,
              'accessTokenTtlMinutes',
              'auth.',
              min: 5,
              max: 1440,
            ) ??
            60,
        refreshTokenTtlDays:
            r.integer(au, 'refreshTokenTtlDays', 'auth.', min: 1, max: 365) ??
            90,
        adminRefreshTokenTtlDays:
            r.integer(
              au,
              'adminRefreshTokenTtlDays',
              'auth.',
              min: 1,
              max: 365,
            ) ??
            30,
        pbkdf2Iterations:
            r.integer(
              au,
              'pbkdf2Iterations',
              'auth.',
              min: 100000,
              max: 5000000,
            ) ??
            600000,
      );
    }

    var imageCache = const ImageCacheSettings();
    final ic = r.map(root, 'imageCache');
    if (ic != null) {
      r.checkKeys(ic, 'imageCache.', const {
        'maxBytes',
        'newRemoteEntriesPerUserPerMinute',
      });
      imageCache = ImageCacheSettings(
        maxBytes:
            r.integer(ic, 'maxBytes', 'imageCache.', min: 1 << 20) ??
            1073741824,
        newRemoteEntriesPerUserPerMinute:
            r.integer(
              ic,
              'newRemoteEntriesPerUserPerMinute',
              'imageCache.',
              min: 0,
            ) ??
            300,
      );
    }

    final hosts = r.stringList(root, 'remoteImageHosts');
    final validHost = RegExp(
      r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$',
    );
    final remoteHosts = <String>[];
    for (final h in hosts ?? defaultRemoteImageHosts) {
      final lower = h.trim().toLowerCase();
      if (!validHost.hasMatch(lower)) {
        errors.add('remoteImageHosts: "$h" is not a host name');
      } else {
        remoteHosts.add(lower);
      }
    }

    return PolicyConfig(
      publicUrls: publicUrls,
      externalApps: externalApps,
      policy: policy,
      alerts: alerts,
      auth: auth,
      imageCache: imageCache,
      remoteImageHosts: remoteHosts,
    );
  }
}

final class _Reader {
  _Reader(this.errors);

  final List<String> errors;

  void checkKeys(Map<Object?, Object?> m, String prefix, Set<String> allowed) {
    for (final k in m.keys) {
      if (!allowed.contains('$k')) errors.add('$prefix$k: unknown key');
    }
  }

  Map<Object?, Object?>? map(
    Map<Object?, Object?> m,
    String key, [
    String prefix = '',
  ]) {
    final v = m[key];
    if (v == null) return null;
    if (v is Map) return v;
    errors.add('$prefix$key must be a mapping');
    return null;
  }

  String? string(Map<Object?, Object?> m, String key, [String prefix = '']) {
    final v = m[key];
    if (v == null) return null;
    if (v is String) return v;
    errors.add('$prefix$key must be a string');
    return null;
  }

  bool? boolean(Map<Object?, Object?> m, String key, [String prefix = '']) {
    final v = m[key];
    if (v == null) return null;
    if (v is bool) return v;
    errors.add('$prefix$key must be true or false');
    return null;
  }

  int? integer(
    Map<Object?, Object?> m,
    String key,
    String prefix, {
    int? min,
    int? max,
  }) {
    final v = m[key];
    if (v == null) return null;
    if (v is! int) {
      errors.add('$prefix$key must be an integer');
      return null;
    }
    if ((min != null && v < min) || (max != null && v > max)) {
      errors.add('$prefix$key must be between ${min ?? '-'} and ${max ?? '-'}');
      return null;
    }
    return v;
  }

  double? number(
    Map<Object?, Object?> m,
    String key,
    String prefix, {
    double? min,
    double? max,
  }) {
    final v = m[key];
    if (v == null) return null;
    if (v is! num) {
      errors.add('$prefix$key must be a number');
      return null;
    }
    final d = v.toDouble();
    if ((min != null && d < min) || (max != null && d > max)) {
      errors.add('$prefix$key must be between $min and $max');
      return null;
    }
    return d;
  }

  List<String>? stringList(
    Map<Object?, Object?> m,
    String key, [
    String prefix = '',
  ]) {
    final v = m[key];
    if (v == null) return null;
    if (v is List && v.every((e) => e is String)) {
      return List.unmodifiable(v.cast<String>());
    }
    errors.add('$prefix$key must be a list of strings');
    return null;
  }
}
